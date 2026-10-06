#!/usr/bin/env bash
# ci-harness — dependency-free OpenTelemetry span emitter (estate telemetry contract).
#
# Why a shell emitter: the contract asks producers to need no vendor library.
# A GitHub runner already has bash, curl and sha256sum, so this script is the
# whole dependency set — nothing to install, no action pin to bump. jq is never
# required; nothing here changes when it is missing.
#
# Transport (contract §1): OTLP over HTTP, JSON, POST to
# $OTEL_EXPORTER_OTLP_TRACES_ENDPOINT or $OTEL_EXPORTER_OTLP_ENDPOINT at
# /v1/traces. Unset endpoint means off. Sending is fire-and-forget: a 2-second
# timeout, no retries, and a failed export is dropped and remembered (a circuit
# breaker) rather than retried. curl's stderr is discarded on purpose — a curl
# transport error prints the host it tried, and private topology never goes to a
# log.
#
# Never raises into the caller: every failure path prints a note and exits 0.
# Usage errors exit 2 so a caller bug is visible; a caller that cares (every
# step in .github/workflows is continue-on-error) keeps its job outcome.
#
# CALLING CONVENTION
#
#   otel-span.sh --self-test
#       Exercise the emitter end to end without GitHub: no endpoint (emits
#       nothing), a loopback receiver (one valid OTLP/JSON body), and an
#       unreachable endpoint (fails nothing). Exits 0 when every check holds.
#
#   otel-span.sh task-trace <mission-id> <task-id>
#       Print the contract §2 traceparent for a mission task:
#         trace id  = first 32 hex of sha256("estate-task|" + mission + "|" + task)
#         root span = first 16 hex of sha256("estate-task-root|" + mission + "|" + task)
#         traceparent = 00-<trace id>-<root span id>-01
#       An all-zero id prefix (about 1 in 2^128) flips its last hex digit to 1,
#       because W3C forbids an all-zero id.
#
#   otel-span.sh traceparent [--traceparent <value>]
#       Print the trace context this run would use, or nothing when telemetry
#       is off. Used to attach `traceparent` to an outbound HTTP call.
#       Precedence: --traceparent, then $TRACEPARENT, then the `Estate-Task`
#       commit trailer, then a trace derived from the run id.
#
#   otel-span.sh ci-open --span-name <name> [--change-id <pr>]
#       Begin a CI job span: resolve the trace context, record the start time,
#       and remember it for ci-close. Emits nothing yet — a span is sent when
#       its work is over, so the closing step can carry the real result.
#
#   otel-span.sh ci-close --span-name <name> --result <job.status>
#       Close the span and send one OTLP body holding the pipeline span and the
#       job span. --result is success | failure | cancelled | anything else.
#
# ENVIRONMENT (all optional; empty or unset means "not provided")
#   OTEL_EXPORTER_OTLP_ENDPOINT      OTLP base endpoint; /v1/traces is appended
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT  per-signal endpoint, wins when both set
#   OTEL_SERVICE_NAME                service.name  (default ci-harness)
#   OTEL_DEPLOYMENT_ENVIRONMENT      deployment.environment.name (default lab)
#   ESTATE_HOST_CLASS                estate.host.class for a self-hosted
#                                    runner; one of dev-vm, bazzite, dockerhost,
#                                    stack-vm, github-hosted, unknown
#   TRACEPARENT / OTEL_TRACEPARENT   inbound trace context
#   OTEL_VCS_CHANGE_ID               vcs.change.id (the pull request number)
#   OTEL_REPO_ROOT                   repository to read the Estate-Task trailer
#                                    from (default $GITHUB_WORKSPACE)
#   RUNNER_ENVIRONMENT               github-hosted | self-hosted
#   OTEL_SPAN_STATE_DIR              where ci-open/ci-close meet (default
#                                    $RUNNER_TEMP/otel-span)
#
# WHAT IS NEVER SENT: secrets, tokens, cookies, Authorization headers,
# prompts, private notes, conversation text, URL query strings, request or
# response bodies, file contents, IP addresses, host names, runner names or
# home-directory paths. Spans carry ids and enumerated vocabulary only.

set -uo pipefail

readonly SCOPE_NAME="ci-harness/otel-span"
readonly SCOPE_VERSION="1"
readonly EXPORT_TIMEOUT_SECONDS=2
readonly CONTRACT_NAMESPACE="estate"
readonly DEFAULT_ENVIRONMENT_NAME="lab"
readonly DEFAULT_SERVICE_NAME="ci-harness"

# ---------------------------------------------------------------- primitives

log() { printf 'otel-span: %s\n' "$*"; }

now_ns() {
  local n
  n=$(date +%s%N 2>/dev/null) || n=""
  case "$n" in
    "" | *[!0-9]*) printf '%s' "$(( $(date +%s) * 1000000000 ))" ;;
    *) printf '%s' "$n" ;;
  esac
}

sha256_hex() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum 2>/dev/null) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | shasum -a 256 2>/dev/null) || return 1
  else
    return 1
  fi
  printf '%s' "${out%% *}"
}

# W3C forbids an all-zero trace or span id; a digest prefix of all zeros gets
# its last hex digit flipped to 1 (~1 in 2^128).
nonzero_id() {
  case "$1" in
    *[!0]*) printf '%s' "$1" ;;
    *) printf '%s1' "${1%?}" ;;
  esac
}

# Attribute values come from git refs and workflow names, which may legally
# contain a quote. Escape before they reach the JSON body.
json_escape() {
  local s
  s=$(printf '%s' "${1-}" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_string() { printf '"%s"' "$(json_escape "$1")"; }

# --------------------------------------------------------------- trace context

# estate_task_trace <mission-id> <task-id> -> "<trace id> <root span id>"
estate_task_trace() {
  local mission=${1-} task=${2-} trace_digest span_digest trace_id span_id
  [ -n "$mission" ] && [ -n "$task" ] || return 1
  trace_digest=$(sha256_hex "estate-task|${mission}|${task}") || return 1
  span_digest=$(sha256_hex "estate-task-root|${mission}|${task}") || return 1
  trace_id=$(nonzero_id "${trace_digest:0:32}")
  span_id=$(nonzero_id "${span_digest:0:16}")
  printf '%s %s' "$trace_id" "$span_id"
}

valid_traceparent() {
  case "${1-}" in
    [0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f]) ;;
    *) return 1 ;;
  esac
  case "${1}" in
    00-00000000000000000000000000000000-* | *-0000000000000000-*) return 1 ;;
  esac
  return 0
}

random_hex32() {
  local n=""
  if [ -r /dev/urandom ]; then
    n=$(LC_ALL=C tr -dc '0-9a-f' < /dev/urandom 2>/dev/null | head -c 32) || n=""
  fi
  if [ "${#n}" -lt 32 ]; then
    n=$(sha256_hex "otel-span-entropy|$$|$RANDOM|$(now_ns)") || return 1
  fi
  printf '%s' "${n:0:32}"
}

# A trace for work the mission did not tag: the whole run shares one trace, so
# the spans of every job correlate without any shared state or extra call.
run_trace() {
  local run_id=${GITHUB_RUN_ID:-}
  if [ -n "$run_id" ]; then
    local digest
    digest=$(sha256_hex "ci-run|${run_id}") || return 1
    printf '%s' "$(nonzero_id "${digest:0:32}")"
    return 0
  fi
  random_hex32
}

# Deterministic span ids — one per run for the pipeline span, one per
# (run, job) for the job span. A span that is emitted twice therefore collapses
# on its id in a backend instead of appearing as two spans.
pipeline_span_id() {
  local digest
  digest=$(sha256_hex "ci-pipeline|${GITHUB_RUN_ID:-}|${GITHUB_JOB:-unknown}") || return 1
  nonzero_id "${digest:0:16}"
}

job_span_id() {
  local digest
  digest=$(sha256_hex "ci-job|${GITHUB_RUN_ID:-}|${GITHUB_JOB:-unknown}") || return 1
  nonzero_id "${digest:0:16}"
}

# `Estate-Task: <mission_id>/<task_id>` on the head commit is what carries a
# mission task into CI. Anything that does not match the shape exactly is
# ignored — a trailer is attacker-influenced text on a pull request.
read_estate_task() {
  local root=${1-} body line mission task
  [ -n "$root" ] && [ -d "$root" ] || return 1
  body=$(git -C "$root" log -1 --format=%B 2>/dev/null) || return 1
  line=$(printf '%s\n' "$body" | grep -m1 -E '^[[:space:]]*Estate-Task:[[:space:]]*[A-Za-z0-9._~-]+/[A-Za-z0-9._~-]+[[:space:]]*$') || return 1
  line=${line#*:}
  line=${line//[[:space:]]/}
  mission=${line%%/*}
  task=${line#*/}
  case "$mission" in "" | *[!A-Za-z0-9._~-]*) return 1 ;; esac
  case "$task" in "" | */* | *[!A-Za-z0-9._~-]*) return 1 ;; esac
  printf '%s %s' "$mission" "$task"
}

# ------------------------------------------------------------- state and gates

state_dir() { printf '%s' "${OTEL_SPAN_STATE_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/otel-span}"; }

state_file() { printf '%s/%s' "$(state_dir)" "$1"; }

# preflight: 0 = telemetry may run, 1 = telemetry is off (and says why).
preflight() {
  local endpoint circuit
  endpoint=$(otel_endpoint)
  if [ -z "$endpoint" ]; then
    log "no OTLP endpoint configured; telemetry is off and nothing was emitted"
    return 1
  fi
  if [ -f "$(state_file circuit-open)" ]; then
    log "circuit is open after an earlier failed export; not sending again this job"
    return 1
  fi
  case "$(printf '%s' "${RUNNER_ENVIRONMENT:-}" | LC_ALL=C tr 'A-Z' 'a-z')" in
    github-hosted | github | githubhosted | github-hosted-runner)
      log "skipped: GitHub-hosted runner cannot reach the LAN Collector"
      return 1
      ;;
  esac
  if ! command -v curl >/dev/null 2>&1; then
    log "curl is not available; telemetry is off"
    return 1
  fi
  circuit=$(state_dir)
  mkdir -p "$circuit" 2>/dev/null || true
  return 0
}

otel_endpoint() {
  local base
  base=${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT:-${OTEL_EXPORTER_OTLP_ENDPOINT:-}}
  [ -n "$base" ] || return 0
  base=${base%/}
  case "$base" in
    */v1/traces) printf '%s' "$base" ;;
    *) printf '%s/v1/traces' "$base" ;;
  esac
}

# Self-hosted runners cannot report which machine they are without reporting
# the machine, and the machine name is exactly the private topology the
# contract forbids. So the class is declared by the consumer's own variables,
# and anything undeclared is `unknown`.
host_class() {
  case "${ESTATE_HOST_CLASS:-}" in
    dev-vm | bazzite | dockerhost | stack-vm | github-hosted | unknown)
      printf '%s' "$ESTATE_HOST_CLASS"
      return 0
      ;;
    "") ;;
    *) log "ignoring ESTATE_HOST_CLASS: not one of dev-vm, bazzite, dockerhost, stack-vm, github-hosted, unknown"
      ;;
  esac
  case "$(printf '%s' "${RUNNER_ENVIRONMENT:-}" | LC_ALL=C tr 'A-Z' 'a-z')" in
    github-hosted | github | githubhosted | github-hosted-runner) printf 'github-hosted' ;;
    *) printf 'unknown' ;;
  esac
}

# ------------------------------------------------------------------ CI spans

cmd_ci_open() {
  local span_name="" change_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --span-name) span_name=${2-}; shift 2 ;;
      --change-id) change_id=${2-}; shift 2 ;;
      --traceparent) OTEL_TRACEPARENT=${2-}; shift 2 ;;
      *) shift ;;
    esac
  done

  preflight || return 0

  local trace_id="" parent_span_id="" pipeline_id="" job_id=""
  local mission_id="" task_id=""
  local inbound=${OTEL_TRACEPARENT:-${TRACEPARENT:-}}
  local ids task

  if [ -n "$inbound" ] && valid_traceparent "$inbound"; then
    trace_id=$(printf '%s' "$inbound" | cut -d- -f2)
    parent_span_id=$(printf '%s' "$inbound" | cut -d- -f3)
  else
    task=$(read_estate_task "${OTEL_REPO_ROOT:-${GITHUB_WORKSPACE:-}}")
    if [ -n "$task" ]; then
      mission_id=${task%% *}
      task_id=${task#* }
      ids=$(estate_task_trace "$mission_id" "$task_id") || ids=""
      if [ -n "$ids" ]; then
        trace_id=${ids%% *}
        parent_span_id=${ids#* }
      fi
    fi
    if [ -z "$trace_id" ]; then
      trace_id=$(run_trace) || trace_id=""
    fi
  fi

  if [ -z "$trace_id" ]; then
    log "could not resolve a trace id; telemetry is off for this step"
    return 0
  fi

  # Deterministic span ids, so a repeated emit of the same span collapses in a
  # backend instead of showing up as duplicates.
  pipeline_id=$(pipeline_span_id) || pipeline_id=""
  job_id=$(job_span_id) || job_id=""
  if [ -z "$pipeline_id" ] || [ -z "$job_id" ]; then
    log "cannot derive span ids; telemetry is off for this step"
    return 0
  fi

  local dir
  dir=$(state_dir)
  mkdir -p "$dir" 2>/dev/null || {
    log "cannot create a state directory; telemetry is off for this step"
    return 0
  }

  {
    printf 'trace_id=%s\n' "$trace_id"
    printf 'parent_span_id=%s\n' "$parent_span_id"
    printf 'pipeline_span_id=%s\n' "$pipeline_id"
    printf 'job_span_id=%s\n' "$job_id"
    printf 'start_ns=%s\n' "$(now_ns)"
    printf 'span_name=%s\n' "$span_name"
    printf 'change_id=%s\n' "$change_id"
    printf 'host_class=%s\n' "$(host_class)"
    printf 'mission_id=%s\n' "$mission_id"
    printf 'task_id=%s\n' "$task_id"
  } > "$(state_file open)" 2>/dev/null || {
    log "cannot record span state; telemetry is off for this step"
    return 0
  }

  if [ -n "$mission_id" ]; then
    log "job span open (trace $trace_id) joined to mission=$mission_id task=$task_id"
  else
    log "job span open (trace $trace_id) with no Estate-Task trailer; correlated by vcs.change.id"
  fi
  return 0
}

state_get() {
  local key=$1 file
  file=$(state_file open)
  [ -f "$file" ] || return 1
  grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2-
}

cmd_ci_close() {
  local span_name="" result=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --span-name) span_name=${2-}; shift 2 ;;
      --result) result=${2-}; shift 2 ;;
      --change-id) OTEL_VCS_CHANGE_ID=${2-}; shift 2 ;;
      *) shift ;;
    esac
  done

  preflight || return 0

  local trace_id parent_span_id pipeline_span_id job_span_id start_ns recorded_name
  local change_id host_class_value mission_id task_id
  if ! trace_id=$(state_get trace_id) || [ -z "$trace_id" ]; then
    log "no job span was opened; nothing to close"
    return 0
  fi
  parent_span_id=$(state_get parent_span_id) || parent_span_id=""
  pipeline_span_id=$(state_get pipeline_span_id) || pipeline_span_id=""
  job_span_id=$(state_get job_span_id) || job_span_id=""
  start_ns=$(state_get start_ns) || start_ns=""
  recorded_name=$(state_get span_name) || recorded_name=""
  change_id=$(state_get change_id) || change_id=""
  host_class_value=$(state_get host_class) || host_class_value=""
  mission_id=$(state_get mission_id) || mission_id=""
  task_id=$(state_get task_id) || task_id=""
  [ -n "$recorded_name" ] && span_name=$recorded_name

  # The result comes from the job's real outcome, never from telemetry state:
  # a span reports what happened, it does not decide.
  local outcome_code="STATUS_CODE_OK" pipeline_result="success"
  case "$result" in
    success) ;;
    cancelled)
      pipeline_result="cancelled"
      outcome_code="STATUS_CODE_UNSET"
      ;;
    failure)
      pipeline_result="failure"
      outcome_code="STATUS_CODE_ERROR"
      ;;
    *)
      pipeline_result="error"
      outcome_code="STATUS_CODE_ERROR"
      ;;
  esac

  local end_ns
  end_ns=$(now_ns)
  [ -n "$start_ns" ] || start_ns=$end_ns
  [ "$end_ns" -ge "$start_ns" ] 2>/dev/null || start_ns=$end_ns

  local run_id=${GITHUB_RUN_ID:-unknown}
  local run_attempt=${GITHUB_RUN_ATTEMPT:-1}
  local job_key=${GITHUB_JOB:-unknown}
  local pipeline_name=${GITHUB_WORKFLOW:-unknown}
  local repository=${GITHUB_REPOSITORY:-unknown}
  local revision=${GITHUB_SHA:-}
  # GITHUB_REF_NAME is "123/merge" on a pull request; the source branch is the
  # ref the work is actually on.
  local ref=${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}

  local body
  body=$(build_body \
    "$trace_id" "$parent_span_id" "$pipeline_span_id" "$job_span_id" \
    "$start_ns" "$end_ns" "$span_name" "$pipeline_result" "$outcome_code" \
    "$pipeline_name" "$run_id" "$job_key" "$run_attempt" "$repository" \
    "$ref" "$revision" "$change_id" "$host_class_value" "$mission_id" "$task_id") || body=""

  if [ -z "$body" ]; then
    log "could not build an OTLP body; nothing was sent"
    return 0
  fi

  send_otlp "$body"
  return 0
}

build_body() {
  local trace_id=$1 parent_span_id=$2 pipeline_span_id=$3 job_span_id=$4
  local start_ns=$5 end_ns=$6 span_name=$7 pipeline_result=$8 outcome_code=$9
  local pipeline_name=${10} run_id=${11} job_key=${12} run_attempt=${13}
  local repository=${14} ref=${15} revision=${16} change_id=${17}
  local host_class_value=${18} mission_id=${19} task_id=${20}

  local attrs="" parent_field=""
  add_attr() { [ -n "${2-}" ] && attrs="${attrs}{\"key\":\"$1\",\"value\":{\"stringValue\":\"$(json_escape "$2")\"}},"; return 0; }

  # Attributes shared by both spans: which pipeline, which run, which code
  # change, where it ran coarsely, and who acted. Ids and enums only.
  add_attr "cicd.pipeline.name" "$pipeline_name"
  add_attr "cicd.pipeline.run.id" "$run_id"
  add_attr "cicd.pipeline.result" "$pipeline_result"
  add_attr "cicd.worker.name" "estate-worker-${host_class_value}"
  add_attr "estate.host.class" "$host_class_value"
  add_attr "estate.actor.kind" "ci"
  add_attr "vcs.repository.name" "$repository"
  add_attr "vcs.ref.head.name" "$ref"
  add_attr "vcs.ref.head.revision" "$revision"
  add_attr "vcs.change.id" "$change_id"
  add_attr "estate.mission.id" "$mission_id"
  add_attr "estate.task.id" "$task_id"
  local shared=${attrs%,}

  add_attr "cicd.pipeline.task.name" "$span_name"
  add_attr "cicd.pipeline.task.run.id" "${run_id}.${run_attempt}-${job_key}"
  add_attr "cicd.pipeline.task.run.result" "$pipeline_result"
  local job_attrs=${attrs%,}

  attrs=""
  add_attr "service.namespace" "$CONTRACT_NAMESPACE"
  add_attr "service.name" "${OTEL_SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"
  add_attr "deployment.environment.name" "${OTEL_DEPLOYMENT_ENVIRONMENT:-$DEFAULT_ENVIRONMENT_NAME}"
  local resource_attrs=${attrs%,}

  [ -n "$parent_span_id" ] && parent_field=$(printf ',"parentSpanId":"%s"' "$parent_span_id")

  printf '{"resourceSpans":[{"resource":{"attributes":[%s]},"scopeSpans":[{"scope":{"name":"%s","version":"%s"},"spans":[' \
    "$resource_attrs" "$SCOPE_NAME" "$SCOPE_VERSION"
  printf '{"traceId":"%s","spanId":"%s"%s,"name":%s,"kind":"SPAN_KIND_INTERNAL","startTimeUnixNano":"%s","endTimeUnixNano":"%s","attributes":[%s],"status":{"code":"%s"}},' \
    "$trace_id" "$pipeline_span_id" "$parent_field" "$(json_string "$pipeline_name")" \
    "$start_ns" "$end_ns" "$shared" "$outcome_code"
  printf '{"traceId":"%s","spanId":"%s","parentSpanId":"%s","name":%s,"kind":"SPAN_KIND_INTERNAL","startTimeUnixNano":"%s","endTimeUnixNano":"%s","attributes":[%s],"status":{"code":"%s"}}' \
    "$trace_id" "$job_span_id" "$pipeline_span_id" "$(json_string "$span_name")" \
    "$start_ns" "$end_ns" "$job_attrs" "$outcome_code"
  printf ']}]}]}'
}

send_otlp() {
  local body=$1 endpoint code rc
  endpoint=$(otel_endpoint)
  # curl's own error text names the host it dialled, so stderr goes nowhere and
  # only the exit code is reported. The endpoint is never printed.
  code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time "$EXPORT_TIMEOUT_SECONDS" \
    --request POST \
    --header "Content-Type: application/json" \
    --data-binary "$body" \
    "$endpoint" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "export failed (curl exit $rc); the span is dropped and no retry is attempted"
    : > "$(state_file circuit-open)" 2>/dev/null || true
    return 0
  fi
  case "$code" in
    2??) log "span exported (HTTP $code)" ;;
    *)
      log "collector refused the export (HTTP $code); the span is dropped and no retry is attempted"
      : > "$(state_file circuit-open)" 2>/dev/null || true
      ;;
  esac
  return 0
}

# --------------------------------------------------------------- traceparent

cmd_traceparent() {
  local requested=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --traceparent) requested=${2-}; shift 2 ;;
      *) shift ;;
    esac
  done
  otel_endpoint >/dev/null 2>&1
  if [ -z "$(otel_endpoint)" ]; then
    return 0
  fi

  local trace_id parent_span_id ids task
  if [ -n "$requested" ] && valid_traceparent "$requested"; then
    trace_id=$(printf '%s' "$requested" | cut -d- -f2)
    parent_span_id=$(printf '%s' "$requested" | cut -d- -f3)
  else
    local recorded
    if recorded=$(state_get trace_id) && [ -n "$recorded" ]; then
      # Whatever ci-open decided, so a header this job attaches lands in the
      # same trace as the spans this job emits.
      trace_id=$recorded
      parent_span_id=$(state_get parent_span_id) || parent_span_id=""
      if [ -z "$parent_span_id" ]; then
        parent_span_id=$(state_get pipeline_span_id) || parent_span_id=""
      fi
    else
      task=$(read_estate_task "${OTEL_REPO_ROOT:-${GITHUB_WORKSPACE:-}}")
      if [ -n "$task" ]; then
        ids=$(estate_task_trace "${task%% *}" "${task#* }") || ids=""
        if [ -n "$ids" ]; then
          trace_id=${ids%% *}
          parent_span_id=${ids#* }
        fi
      fi
      if [ -z "$trace_id" ]; then
        # No mission context: this run is its own trace, and the pipeline span
        # is its root, so that is the span a downstream call hangs off.
        trace_id=$(run_trace) || return 0
        parent_span_id=$(pipeline_span_id) || parent_span_id=""
      fi
    fi
  fi
  [ -n "$parent_span_id" ] || return 0
  printf '00-%s-%s-01' "$trace_id" "$parent_span_id"
}

# ------------------------------------------------------------------ self-test

# One loopback OTLP receiver, started and stopped by the test itself. python3
# is only used here — the emitter itself never needs it.
self_test_receiver() {
  command -v python3 >/dev/null 2>&1 || return 1
  local body_file=$1 port_file=$2
  OTEL_SELF_TEST_BODY="$body_file" OTEL_SELF_TEST_PORT="$port_file" python3 - >/dev/null 2>&1 <<'PY' &
import http.server
import os
import sys

body_path = os.environ["OTEL_SELF_TEST_BODY"]
port_path = os.environ["OTEL_SELF_TEST_PORT"]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        with open(body_path, "wb") as handle:
            handle.write(self.rfile.read(length))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
  # Its stdout must not stay attached to the caller's pipe, or a caller that
  # captures this function's pid would block until the receiver dies.
  local pid=$!
  local waited=0
  while [ ! -s "$port_file" ]; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -gt 100 ] && break
  done
  [ -s "$port_file" ] || {
    kill "$pid" 2>/dev/null
    return 1
  }
  printf '%s' "$pid"
}

self_test() {
  local failures=0 port receiver_pid body_file expected_trace expected_span
  SELF_TEST_TMP=$(mktemp -d 2>/dev/null) || {
    log "SELF-TEST FAILED: cannot create a temporary directory"
    return 1
  }
  # A RETURN trap would run after the local went out of scope, so the scratch
  # directory is removed explicitly at the end of every path below.
  local tmp=$SELF_TEST_TMP
  trap 'rm -rf "$SELF_TEST_TMP"' EXIT

  # 1. Unset endpoint means off: nothing is emitted and nothing fails.
  if env -u OTEL_EXPORTER_OTLP_ENDPOINT -u OTEL_EXPORTER_OTLP_TRACES_ENDPOINT \
    OTEL_SPAN_STATE_DIR="$tmp/state-empty" \
    bash "$0" ci-open --span-name self-test >"$tmp/no-endpoint.log" 2>&1 &&
    grep -q "no OTLP endpoint configured" "$tmp/no-endpoint.log"; then
    echo "self-test: no endpoint configured -> emitted nothing, exit 0"
  else
    echo "self-test FAILED: an unset endpoint did not report telemetry off"
    failures=$((failures + 1))
  fi

  # 2. A loopback receiver: exactly one valid OTLP/JSON body, carrying the trace
  #    the contract recipe computes for the mission task in the trailer.
  receiver_pid=$(self_test_receiver "$tmp/body.json" "$tmp/port")
  if [ -n "$receiver_pid" ]; then
    port=$(cat "$tmp/port")
    body_file=$tmp/body.json
    expected_trace=$(printf 'estate-task|m-1|t-1' | sha256sum | cut -c1-32)
    expected_span=$(printf 'estate-task-root|m-1|t-1' | sha256sum | cut -c1-16)

    local repo="$tmp/repo"
    mkdir -p "$repo"
    git -C "$repo" init -q 2>/dev/null
    git -C "$repo" config user.email self-test@example.invalid 2>/dev/null
    git -C "$repo" config user.name self-test 2>/dev/null
    printf 'fixture\n' > "$repo/README"
    git -C "$repo" add README
    # The head commit carries the trailer the CI reporter reads to join the
    # mission task trace.
    git -C "$repo" commit -q -m "fixture" -m "Estate-Task: m-1/t-1" 2>/dev/null

    env OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:${port}" \
      OTEL_SPAN_STATE_DIR="$tmp/state-live" \
      OTEL_REPO_ROOT="$repo" \
      GITHUB_RUN_ID="4242" GITHUB_RUN_ATTEMPT="1" GITHUB_JOB="self-test" \
      GITHUB_WORKFLOW="self-smoke" GITHUB_REPOSITORY="Rylee-Bee/ci-harness" \
      GITHUB_HEAD_REF="feature/branch" GITHUB_SHA="0000000000000000000000000000000000000000" \
      RUNNER_ENVIRONMENT="self-hosted" ESTATE_HOST_CLASS="dockerhost" \
      bash "$0" ci-open --span-name "self-test job" --change-id "17" >"$tmp/open.log" 2>&1
    env OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:${port}" \
      OTEL_SPAN_STATE_DIR="$tmp/state-live" \
      OTEL_REPO_ROOT="$repo" \
      GITHUB_RUN_ID="4242" GITHUB_RUN_ATTEMPT="1" GITHUB_JOB="self-test" \
      GITHUB_WORKFLOW="self-smoke" GITHUB_REPOSITORY="Rylee-Bee/ci-harness" \
      GITHUB_HEAD_REF="feature/branch" GITHUB_SHA="0000000000000000000000000000000000000000" \
      RUNNER_ENVIRONMENT="self-hosted" ESTATE_HOST_CLASS="dockerhost" \
      bash "$0" ci-close --span-name "self-test job" --result success >>"$tmp/open.log" 2>&1

    local check_failed=0
    [ -s "$body_file" ] || { echo "self-test FAILED: the receiver captured no body"; check_failed=1; }
    if [ "$check_failed" -eq 0 ]; then
      grep -q "\"traceId\":\"${expected_trace}\"" "$body_file" ||
        { echo "self-test FAILED: trace id is not sha256(\"estate-task|m-1|t-1\")[0:32]"; check_failed=1; }
      # The mission task's root span is the parent of this work, never
      # re-emitted: the task's own root span belongs to the mission log.
      grep -q "\"parentSpanId\":\"${expected_span}\"" "$body_file" ||
        { echo "self-test FAILED: the spans do not hang off sha256(\"estate-task-root|m-1|t-1\")[0:16]"; check_failed=1; }
      grep -q '"key":"estate.mission.id","value":{"stringValue":"m-1"}}' "$body_file" ||
        { echo "self-test FAILED: the Estate-Task trailer did not reach estate.mission.id"; check_failed=1; }
      grep -q '"key":"estate.task.id","value":{"stringValue":"t-1"}}' "$body_file" ||
        { echo "self-test FAILED: the Estate-Task trailer did not reach estate.task.id"; check_failed=1; }
      grep -q '"key":"estate.host.class","value":{"stringValue":"dockerhost"}}' "$body_file" ||
        { echo "self-test FAILED: estate.host.class did not reach the span"; check_failed=1; }
      grep -q '"key":"cicd.pipeline.result","value":{"stringValue":"success"}}' "$body_file" ||
        { echo "self-test FAILED: cicd.pipeline.result did not carry the real job outcome"; check_failed=1; }
      grep -q '"resourceSpans"' "$body_file" || { echo "self-test FAILED: body is not an OTLP resourceSpans document"; check_failed=1; }
      grep -q '"cicd.pipeline.task.run.result"' "$body_file" || { echo "self-test FAILED: job span carries no cicd.pipeline.task.run.result"; check_failed=1; }
      grep -q '"vcs.change.id"' "$body_file" || { echo "self-test FAILED: body carries no vcs.change.id"; check_failed=1; }
      if grep -qE '"(Authorization|cookie|host\.name|net\.peer\.ip|url\.query)"' "$body_file"; then
        echo "self-test FAILED: the body carries an attribute the contract forbids"
        check_failed=1
      fi
      if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); spans=d["resourceSpans"][0]["scopeSpans"][0]["spans"]; assert len(spans)==2, len(spans)' "$body_file" ||
          { echo "self-test FAILED: the body is not valid JSON with two spans"; check_failed=1; }
      fi
    fi
    if [ "$check_failed" -eq 0 ]; then
      echo "self-test: loopback receiver -> one valid OTLP/JSON body, exit 0"
    else
      failures=$((failures + 1))
    fi

    # 3. Unreachable endpoint: dropped, circuit open, still exit 0.
    if env OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:1" \
      OTEL_SPAN_STATE_DIR="$tmp/state-dead" \
      RUNNER_ENVIRONMENT="self-hosted" \
      bash "$0" ci-close --span-name "self-test job" --result failure >"$tmp/dead.log" 2>&1; then
      echo "self-test: unreachable endpoint -> export dropped, exit 0"
    else
      echo "self-test FAILED: an unreachable endpoint changed the exit code"
      failures=$((failures + 1))
    fi

    # 4. GitHub-hosted runners cannot reach the LAN Collector; say so, stay green.
    if env OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:${port}" \
      OTEL_SPAN_STATE_DIR="$tmp/state-hosted" \
      RUNNER_ENVIRONMENT="GitHub" \
      bash "$0" ci-open --span-name "self-test job" >"$tmp/hosted.log" 2>&1 &&
      grep -q "skipped: GitHub-hosted runner cannot reach the LAN Collector" "$tmp/hosted.log"; then
      echo "self-test: GitHub-hosted runner -> skipped with an explicit line, exit 0"
    else
      echo "self-test FAILED: a GitHub-hosted runner did not report the LAN Collector skip"
      failures=$((failures + 1))
    fi

    kill "$receiver_pid" 2>/dev/null
    wait "$receiver_pid" 2>/dev/null
  else
    echo "self-test SKIPPED: no loopback receiver available (python3 missing)"
  fi

  if [ "$failures" -ne 0 ]; then
    echo "self-test: $failures check(s) failed"
    return 1
  fi
  echo "self-test: all checks passed"
  return 0
}

usage() {
  printf 'usage: %s {--self-test | task-trace MISSION TASK | traceparent | ci-open --span-name N | ci-close --span-name N --result R}\n' "$0" >&2
}

main() {
  local command=${1-}
  shift || true
  case "$command" in
    --self-test) self_test ;;
    task-trace)
      local ids
      ids=$(estate_task_trace "${1-}" "${2-}") || {
        log "cannot compute a trace id (mission and task are required)"
        return 2
      }
      printf '00-%s-%s-01\n' "${ids%% *}" "${ids#* }"
      ;;
    traceparent) cmd_traceparent "$@" ;;
    ci-open) cmd_ci_open "$@" ;;
    ci-close) cmd_ci_close "$@" ;;
    -h | --help | "") usage; [ -n "$command" ] && return 0 || return 2 ;;
    *)
      usage
      log "unknown command: $command"
      return 2
      ;;
  esac
}

main "$@"
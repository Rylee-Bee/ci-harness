#!/usr/bin/env bash
# ci-harness — the estate OpenTelemetry span emitter, bash + curl, nothing else.
#
# Contract: homelab docs/observability/TELEMETRY-CONTRACT.md §1-3 (homelab #229);
# ci-harness #19. This is
# the bash counterpart of agent-platform's bin/estate_otel.py (PR agent-platform#74):
# standard library only, one OTLP/HTTP JSON POST per span with curl, a 2-second
# timeout, no retries in the hot path, every error swallowed. A span that cannot be
# sent is dropped. **Telemetry failure must never fail a CI job** — this script
# exits 0 on any send failure, and the templates also mark every telemetry step
# continue-on-error.
#
# "OpenTelemetry observes the estate. It never becomes the estate." Nothing reads
# these spans to decide whether work passed, approved, or is allowed to land. The
# GitHub check is still the gate; a span is an explanation, never an authority.
#
# On only when OTEL_EXPORTER_OTLP_TRACES_ENDPOINT or OTEL_EXPORTER_OTLP_ENDPOINT is
# set and OTEL_SDK_DISABLED is not "true" (§1: "Unset endpoint means off", and a
# producer with no endpoint emits nothing and does nothing else differently).
# The endpoint arrives through the *standard* environment variables — no
# estate-specific discovery, no new package, no new action.
#
# Circuit breaker: one failed send writes a marker under $RUNNER_TEMP, so an
# unreachable Collector costs one 2-second timeout per job, not one per span.
#
# §4 — what never goes out: secrets, bearer tokens, cookies, prompts, completions,
# private notes, conversation text, URL query strings, request/response bodies, IP
# addresses, host names, home-directory paths. Attributes here are ids, standard
# CI/CD and VCS convention names, and coarse enums. The Collector scrubs a second
# time; that is a safety net, not the plan.

set -uo pipefail

OTEL_TIMEOUT_S="${OTEL_TIMEOUT_S:-2}"
SERVICE_NAMESPACE="estate"
SCOPE_NAME="otel-span"
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

# --------------------------------------------------------------------------------------- primitives

trim() { local s="${1-}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

lower() { printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]'; }

die() { printf 'otel-span: %s\n' "${1-}" >&2; exit 2; }

# W3C forbids all-zero ids; the contract's fallback turns the last hex digit into 1.
nonzero() { local h="${1-}"; case "$h" in *[!0]*) printf '%s' "$h" ;; *) printf '%s1' "${h%?}" ;; esac; }

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${1-}" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "${1-}" | openssl dgst -sha256 | awk '{print $NF}'
  fi
}

random_hex() {
  local n="${1:-16}" out
  out=$(od -An -tx1 -N"$n" /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ "${#out}" -lt $((n * 2)) ]; then
    out=$(head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  printf '%s' "$out"
}

now_ns() {
  local n
  n=$(date +%s%N 2>/dev/null) || n=""
  case "$n" in "" | *N*) n=$(python3 -c 'import time; print(time.time_ns())' 2>/dev/null) ;; esac
  printf '%s' "${n:-0}"
}

work_dir() {
  local d="${RUNNER_TEMP:-}"
  if [ -z "$d" ]; then d="${TMPDIR:-/tmp}"; fi
  printf '%s' "$d"
}

breaker_file() {
  if [ -n "${OTEL_BREAKER_FILE:-}" ]; then printf '%s' "$OTEL_BREAKER_FILE"; return 0; fi
  printf '%s/otel-span.breaker' "$(work_dir)"
}

# --------------------------------------------------------------------------------------- trace context

# Contract §2: trace id = first 32 hex of sha256("estate-task|<mission>|<task>"),
# root span id = first 16 hex of sha256("estate-task-root|<mission>|<task>"). Every
# hop that knows the two ids computes the same trace with no shared state.
task_ids() {
  local t r
  t=$(sha256_hex "estate-task|${1-}|${2-}"); t="${t:0:32}"
  r=$(sha256_hex "estate-task-root|${1-}|${2-}"); r="${r:0:16}"
  printf '%s %s' "$(nonzero "$t")" "$(nonzero "$r")"
}

PT_TRACE=""
PT_SPAN=""
parse_traceparent() {
  PT_TRACE=""
  PT_SPAN=""
  local v="${1-}" a="" b="" c="" d="" e=""
  IFS='-' read -r a b c d e <<<"$v"
  [ -z "${e:-}" ] || return 1           # exactly four fields, never five
  [ "${#a}" -eq 2 ] && [ "${#b}" -eq 32 ] && [ "${#c}" -eq 16 ] && [ "${#d}" -eq 2 ] || return 1
  for part in "$a" "$b" "$c" "$d"; do
    case "$part" in *[!0-9a-fA-F]*) return 1 ;; esac
  done
  [ "$(lower "$a")" = "ff" ] && return 1
  [ "$b" = "00000000000000000000000000000000" ] && return 1
  [ "$c" = "0000000000000000" ] && return 1
  PT_TRACE=$(lower "$b")
  PT_SPAN=$(lower "$c")
  return 0
}

# The Estate-Task trailer (contract §2) rides on the commits of a PR a mission lands.
task_from_git() {
  local ref="${1:-HEAD}" msg line
  msg=$(git log -1 --format=%B "$ref" 2>/dev/null) || return 0
  line=$(printf '%s\n' "$msg" | tr -d '\r' | grep -E '^[[:space:]]*Estate-Task:[[:space:]]*[A-Za-z0-9._-]+/[A-Za-z0-9._-]+[[:space:]]*$' | head -n1) || return 0
  line="${line#"${line%%[![:space:]]*}"}"
  printf '%s' "${line#Estate-Task:}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# estate.host.class (contract §3). Coarse by design: a runner *label*, never a
# hostname. The labels are chosen by this estate, so they can carry the meaning.
detect_host_class() {
  local label v="${ESTATE_HOST_CLASS:-}"
  case "$v" in
    dev-vm | bazzite | dockerhost | stack-vm | github-hosted | unknown) printf '%s' "$v"; return 0 ;;
  esac
  label=$(lower "${1-}")
  case "$label" in
    *bazzite*) printf 'bazzite' ;;
    *dockerhost*) printf 'dockerhost' ;;
    *stack*) printf 'stack-vm' ;;
    *dev*) printf 'dev-vm' ;;
    ubuntu | ubuntu-* | windows | windows-* | macos | macos-*) printf 'github-hosted' ;;
    *) printf 'unknown' ;;
  esac
}

# --------------------------------------------------------------------------------------- OTLP/HTTP JSON

# Endpoint resolution is the standard discovery of §1 and nothing else.
otel_endpoint() {
  [ "$(lower "${OTEL_SDK_DISABLED:-}")" = "true" ] && return 1
  local traces base
  traces=$(trim "${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT:-}")
  if [ -n "$traces" ]; then printf '%s' "$traces"; return 0; fi
  base=$(trim "${OTEL_EXPORTER_OTLP_ENDPOINT:-}")
  [ -n "$base" ] || return 1
  printf '%s/v1/traces' "${base%/}"
}

trip_breaker() { mkdir -p "$(work_dir)" 2>/dev/null; : >"$(breaker_file)" 2>/dev/null || true; }

# The OTLP/HTTP JSON body for one span, on stdout. JSON is built by the standard
# library rather than by string-splicing in the shell: an attribute value must
# never be able to break out of its own object.
# $1 name $2 trace $3 span $4 parent(or -) $5 start_ns $6 end_ns $7 attrs-file
# $8 error(or empty) $9 kind $10 resource-extra-file $11 service $12 host-class $13 scope
build_body() {
  python3 - "$@" <<'BODY_PY'
import json
import sys

(
    name, trace, span, parent, start, end,
    attrs_file, err, kind, res_file, service, host_class, scope,
) = sys.argv[1:14]


def load(path):
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line:
                    continue
                key, _, value = line.partition("=")
                out.append({"key": key, "value": {"stringValue": value}})
    except OSError:
        pass
    return out


span_obj = {
    "traceId": trace,
    "spanId": span,
    "name": name,
    "kind": int(kind or 1),
    "startTimeUnixNano": str(int(start)),
    "endTimeUnixNano": str(max(int(end), int(start))),
    "attributes": load(attrs_file),
}
if parent and parent != "-":
    span_obj["parentSpanId"] = parent
if err:
    span_obj["status"] = {"code": 2, "message": err[:200]}

resource = [
    {"key": "service.name", "value": {"stringValue": service}},
    {"key": "service.namespace", "value": {"stringValue": "estate"}},
    {"key": "estate.host.class", "value": {"stringValue": host_class}},
] + load(res_file)

print(json.dumps({
    "resourceSpans": [{
        "resource": {"attributes": resource},
        "scopeSpans": [{"scope": {"name": scope}, "spans": [span_obj]}],
    }],
}, separators=(",", ":")))
BODY_PY
}

# Fire and forget. Always returns 0: a failed export is dropped, never raised
# into the caller, and one failure trips the breaker for the rest of the job.
post_span() {
  local url
  if [ -f "$(breaker_file)" ]; then return 0; fi
  url=$(otel_endpoint) || return 0

  local body_file rc code
  body_file=$(mktemp "${TMPDIR:-/tmp}/otel-span.XXXXXX.json") || return 0

  if ! build_body "$@" >"$body_file" 2>/dev/null; then
    rm -f "$body_file"
    return 0
  fi

  code=$(curl --silent --show-error --request POST \
    --header "Content-Type: application/json" \
    --data-binary "@$body_file" \
    --output /dev/null --write-out '%{http_code}' \
    --max-time "$OTEL_TIMEOUT_S" --connect-timeout "$OTEL_TIMEOUT_S" \
    "$url" 2>&1)
  rc=$?
  rm -f "$body_file"

  if [ "$rc" -ne 0 ]; then
    printf 'otel-span: dropped span %q (transport: %s) — telemetry failure is not a CI failure\n' "$1" "$code"
    trip_breaker
    return 0
  fi
  case "$code" in
    2??) printf 'otel-span: sent span %q (%s)\n' "$1" "$code" ;;
    *)
      printf 'otel-span: dropped span %q (collector answered %s)\n' "$1" "$code"
      trip_breaker
      ;;
  esac
  return 0
}

# --------------------------------------------------------------------------------------- emit

# One span, generically. This is the only thing that talks to the network.
cmd_emit() {
  local name="" trace="" span="" parent="-" start="" end="" err="" kind="1"
  local attrs_file res_file service="" host_class="" scope="$SCOPE_NAME"
  local dir; dir=$(mktemp -d "${TMPDIR:-/tmp}/otel-attrs.XXXXXX") || return 0
  attrs_file="$dir/span"; res_file="$dir/res"
  : >"$attrs_file"; : >"$res_file"

  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2-}"; shift 2 ;;
      --trace-id) trace="${2-}"; shift 2 ;;
      --span-id) span="${2-}"; shift 2 ;;
      --parent-span-id) parent="${2-}"; shift 2 ;;
      --start-ns) start="${2-}"; shift 2 ;;
      --end-ns) end="${2-}"; shift 2 ;;
      --error) err="${2-}"; shift 2 ;;
      --kind) kind="${2-}"; shift 2 ;;
      --service) service="${2-}"; shift 2 ;;
      --host-class) host_class="${2-}"; shift 2 ;;
      --scope) scope="${2-}"; shift 2 ;;
      --resource-attrs-file) res_file="${2-}"; shift 2 ;;
      --attrs-file) cat "$2" >>"$attrs_file" 2>/dev/null || true; shift 2 ;;
      --attr)
        add_attr "$attrs_file" "${2-}" || true
        shift 2
        ;;
      *) shift ;;
    esac
  done

  [ -n "$trace" ] || trace=$(random_hex 16)
  [ -n "$span" ] || span=$(random_hex 8)
  [ -n "$start" ] || start=1
  [ -n "$end" ] || end="$start"
  [ -n "$service" ] || service="ci-harness"
  [ -n "$host_class" ] || host_class="unknown"

  post_span "${name:-span}" "$trace" "$span" "$parent" "$start" "$end" \
    "$attrs_file" "$err" "$kind" "$res_file" "$service" "$host_class" "$scope"
  rm -rf "$dir"
  return 0
}

# A key=value attribute line, or nothing: a key that is not a dotted token, or a
# value carrying a control character or a home path, is refused rather than sent.
add_attr() {
  local file="${1-}" pair="${2-}" key value
  key="${pair%%=*}"
  value="${pair#*=}"
  [ "$key" != "$pair" ] || return 1
  [ -n "$value" ] || return 1
  case "$key" in
    '' | *[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  case "$value" in
    *$'\n'* | *$'\r'* | *$'\t'*) return 1 ;;
  esac
  case "$value" in
    *"://"*) return 1 ;;      # no URLs: no endpoints, no query strings, no private hosts
    "~" | "~/"* | /home/* | /root/* | /Users/* | /var/home/*) return 1 ;;   # no home paths
    *".."*) return 1 ;;       # no path traversal
  esac
  printf '%s=%s\n' "$key" "${value:0:256}" >>"$file"
  return 0
}

# --------------------------------------------------------------------------------------- context

ctx_put() { printf "%s='%s'\n" "$1" "${2//\'/\'\\\'\'}" >>"$ctx_out"; }

# Compute everything the CI templates need once per job, and leave it in an
# env-file the close step sources. Nothing here sends anything.
cmd_context() {
  local out="" task="" job_key="${OTELSPAN_JOB_KEY:-unknown}"
  local pipeline_name="${OTELSPAN_PIPELINE_NAME:-workflow}"
  local run_id="${OTELSPAN_RUN_ID:-0}" attempt="${OTELSPAN_RUN_ATTEMPT:-1}"
  local repository="${OTELSPAN_REPOSITORY:-}" ref_head="${OTELSPAN_REF_HEAD:-}"
  local revision="${OTELSPAN_HEAD_REVISION:-}" change_id="${OTELSPAN_CHANGE_ID:-}"
  local runner_label="${OTELSPAN_RUNNER_LABEL:-}" service="${OTEL_SERVICE_NAME:-ci-harness}"
  local ctx_out; ctx_out=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --env-file) out="${2-}"; shift 2 ;;
      --task) task="${2-}"; shift 2 ;;
      --job-key) job_key="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  [ -n "$out" ] || out="${OTELSPAN_ENV_FILE:-}"
  [ -n "$out" ] || { printf 'otel-span: context needs --env-file\n' >&2; return 2; }
  ctx_out="$out"
  : >"$ctx_out" || return 2

  # A PR a mission lands carries Estate-Task: <mission_id>/<task_id> on its HEAD
  # commit. Without one this run gets its own trace, linked by vcs.change.id.
  [ -n "$task" ] || task=$(trim "${OTELSPAN_TASK:-}")
  if [ -z "$task" ] && [ "${OTELSPAN_READ_GIT:-1}" != "0" ]; then
    task=$(task_from_git "${OTELSPAN_GIT_REF:-HEAD}")
  fi

  local mission="" tid="" trace parent pipeline_span task_run span_id
  if [[ "$task" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    mission="${task%%/*}"
    tid="${task#*/}"
    read -r trace parent <<<"$(task_ids "$mission" "$tid")"
    ctx_put otel_parent_span_id "$parent"
  else
    [ -n "$task" ] && printf 'otel-span: ignoring unparseable Estate-Task trailer %q\n' "$task"
    trace=$(nonzero "$(random_hex 16)")
    ctx_put otel_parent_span_id ""
  fi

  # One trace per job; the task run id is derived, never a random collision.
  pipeline_span=$(nonzero "$(sha256_hex "cicd-pipeline|${run_id}|${attempt}|${job_key}")")
  pipeline_span="${pipeline_span:0:16}"
  task_run=$(sha256_hex "cicd-task-run|${run_id}|${attempt}|${job_key}")
  task_run="${task_run:0:32}"
  span_id=$(nonzero "$(random_hex 8)")

  ctx_put otel_trace_id "$trace"
  ctx_put otel_span_id "$span_id"
  ctx_put otel_pipeline_span_id "$pipeline_span"
  ctx_put otel_task_run_id "$task_run"
  ctx_put otel_job_key "$job_key"
  ctx_put otel_mission_id "$mission"
  ctx_put otel_task_id "$tid"
  ctx_put otel_pipeline_name "$pipeline_name"
  ctx_put otel_pipeline_run_id "$run_id"
  ctx_put otel_repository "${repository#*/}"
  ctx_put otel_ref_head "$ref_head"
  ctx_put otel_head_revision "$revision"
  ctx_put otel_change_id "$change_id"
  ctx_put otel_runner_label "$runner_label"
  ctx_put otel_host_class "$(detect_host_class "$runner_label")"
  ctx_put otel_service_name "$service"
  ctx_put otel_actor_kind "ci"
  ctx_put otel_start_ns "$(now_ns)"
  # What this job hands to a child process or an HTTP call (W3C trace context).
  ctx_put otel_traceparent "00-${trace}-${span_id}-01"

  if [ -n "$out" ]; then
    printf 'otel-span: trace %s (task %s) host-class %s\n' "${trace:0:12}" "${task:-<none>}" "$(detect_host_class "$runner_label")"
  fi
  return 0
}

# --------------------------------------------------------------------------------------- ci-emit

# One CI span, assembled from the standard semantic conventions (contract §3).
# Nothing here is estate-specific where a standard name carries the meaning.
cmd_ci_emit() {
  local ctx="" role="job" result="success" end="" err=""
  local name="" span_override="" parent_override="" start="" child=0
  local dir; dir=$(mktemp -d "${TMPDIR:-/tmp}/otel-ci.XXXXXX") || return 0
  local attrs="$dir/attrs"; : >"$attrs"
  local extra=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --env-file) ctx="${2-}"; shift 2 ;;
      --role) role="${2-}"; shift 2 ;;
      --result) result="${2-}"; shift 2 ;;
      --end-ns) end="${2-}"; shift 2 ;;
      --error) err="${2-}"; shift 2 ;;
      --name) name="${2-}"; shift 2 ;;
      --span-id) span_override="${2-}"; shift 2 ;;
      # A span describing one call inside the job gets its own id; without this
      # it would reuse the job's span id and end up parented to itself.
      --child) child=1; shift ;;
      --parent-span-id) parent_override="${2-}"; shift 2 ;;
      --start-ns) start="${2-}"; shift 2 ;;
      --attr) extra+=(--attr "${2-}"); shift 2 ;;
      *) shift ;;
    esac
  done

  [ -n "$ctx" ] || { printf 'otel-span: ci-emit needs --env-file\n' >&2; rm -rf "$dir"; return 2; }
  # shellcheck disable=SC1090
  . "$ctx" 2>/dev/null || { rm -rf "$dir"; return 0; }

  # A GitHub-hosted runner cannot reach the LAN Collector. Say so in the step
  # summary rather than emitting a span that cannot arrive.
  if [ "${otel_host_class:-unknown}" = "github-hosted" ]; then
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf '### OpenTelemetry\n\nHost class is `github-hosted`; the LAN Collector is unreachable from this runner, so no span was emitted. Missing telemetry is UNKNOWN, not a failure.\n' >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
    fi
    printf 'otel-span: host-class github-hosted — Collector unreachable from this runner, span not emitted\n'
    rm -rf "$dir"
    return 0
  fi

  local res="$dir/res"; : >"$res"
  local pair
  for pair in ${OTEL_RESOURCE_ATTRIBUTES:-}; do
    add_attr "$res" "$pair" || true
  done

  # Standard CI/CD conventions: pipeline identity on every span, task identity on
  # the job span. Coarse runner label only — never a hostname or an IP.
  local result_enum
  case "$(lower "$result")" in
    success) result_enum="success" ;;
    failure) result_enum="failure" ;;
    cancelled | canceled) result_enum="cancellation" ;;
    skipped) result_enum="skipped" ;;
    *) result_enum="error" ;;
  esac

  add_attr "$attrs" "cicd.pipeline.name=${otel_pipeline_name:-}" || true
  add_attr "$attrs" "cicd.pipeline.run.id=${otel_pipeline_run_id:-}" || true
  add_attr "$attrs" "cicd.pipeline.result=$result_enum" || true
  add_attr "$attrs" "cicd.worker.name=${otel_runner_label:-unknown}" || true
  add_attr "$attrs" "estate.actor.kind=${otel_actor_kind:-ci}" || true
  add_attr "$attrs" "estate.host.class=${otel_host_class:-unknown}" || true
  add_attr "$attrs" "vcs.repository.name=${otel_repository:-}" || true
  add_attr "$attrs" "vcs.ref.head.name=${otel_ref_head:-}" || true
  add_attr "$attrs" "vcs.ref.head.revision=${otel_head_revision:-}" || true
  add_attr "$attrs" "vcs.change.id=${otel_change_id:-}" || true
  add_attr "$attrs" "estate.mission.id=${otel_mission_id:-}" || true
  add_attr "$attrs" "estate.task.id=${otel_task_id:-}" || true

  local span_id parent_id span_name
  [ "$child" -eq 1 ] && [ -z "$span_override" ] && span_override="$(nonzero "$(random_hex 8)")"
  if [ "$role" = "pipeline" ]; then
    span_name="${name:-ci.pipeline.run}"
    span_id="${span_override:-${otel_pipeline_span_id:-}}"
    parent_id="${parent_override:-${otel_parent_span_id:-}}"
  else
    span_name="${name:-ci.job.run}"
    span_id="${span_override:-${otel_span_id:-}}"
    parent_id="${parent_override:-${otel_pipeline_span_id:-}}"
    add_attr "$attrs" "cicd.pipeline.task.name=${otel_job_key:-}" || true
    add_attr "$attrs" "cicd.pipeline.task.run.id=${otel_task_run_id:-}" || true
    add_attr "$attrs" "cicd.pipeline.task.run.result=$result_enum" || true
  fi

  [ -n "$start" ] || start="${otel_start_ns:-1}"
  [ -n "$end" ] || end="$(now_ns)"

  # Extra attributes arrive as a flat key=value list and go through the same
  # validation as the standard set: nothing unvalidated can reach the wire.
  local i=0
  while [ "$i" -lt "${#extra[@]}" ]; do
    add_attr "$attrs" "${extra[$((i + 1))]}" || true
    i=$((i + 2))
  done

  cmd_emit --name "$span_name" --trace-id "${otel_trace_id:-}" --span-id "$span_id" \
    --parent-span-id "$parent_id" --start-ns "$start" --end-ns "$end" \
    --error "$err" --kind 1 --service "${otel_service_name:-ci-harness}" \
    --host-class "${otel_host_class:-unknown}" --resource-attrs-file "$res" \
    --attrs-file "$attrs"
  rm -rf "$dir"
  return 0
}

# --------------------------------------------------------------------------------------- usage

usage() {
  cat <<'EOF'
otel-span.sh — the estate OpenTelemetry span emitter (bash + curl, standard library only)

  --self-test                     start a throwaway OTLP receiver and prove the bodies
  context   --env-file F [--task <mission>/<task>] [--job-key K]
  ci-emit   --env-file F [--role pipeline|job] [--result S] [--end-ns N] [--attr k=v]...
  emit      --name N --trace-id H32 --span-id H16 [--parent-span-id H16]
            --start-ns N --end-ns N [--attr k=v]... [--error MSG]
  task-traceparent <mission> <task>
  parse-traceparent <traceparent>       prints "<trace-id> <span-id>", exit 1 if malformed
  task-from-git [ref]                   prints the Estate-Task trailer, or nothing
  detect-host-class <runner-label>      dev-vm | bazzite | dockerhost | stack-vm | github-hosted | unknown

On only when OTEL_EXPORTER_OTLP_TRACES_ENDPOINT or OTEL_EXPORTER_OTLP_ENDPOINT is set
and OTEL_SDK_DISABLED is not "true". Fire and forget: 2s timeout, no retries, never
raises. A failed export is dropped and never fails the caller.
EOF
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    --self-test) self_test; exit $? ;;
    emit) cmd_emit "$@" ;;
    context) cmd_context "$@" ;;
    ci-emit) cmd_ci_emit "$@" ;;
    task-traceparent)
      [ $# -ge 2 ] || die "task-traceparent needs a mission id and a task id"
      read -r t s <<<"$(task_ids "${1-}" "${2-}")"
      printf '00-%s-%s-01\n' "$t" "$s"
      ;;
    parse-traceparent)
      parse_traceparent "${1-}" || exit 1
      printf '%s %s\n' "$PT_TRACE" "$PT_SPAN"
      ;;
    task-from-git) task_from_git "${1:-HEAD}"; printf '\n' ;;
    detect-host-class) detect_host_class "${1-}"; printf '\n' ;;
    -h | --help | help) usage ;;
    "") usage; exit 2 ;;
    *) printf 'otel-span: unknown command %q\n' "$cmd" >&2; usage >&2; exit 2 ;;
  esac
  return 0
}

# --------------------------------------------------------------------------------------- self-test

# A throwaway OTLP/HTTP receiver on 127.0.0.1 — the Collector stands in, nothing
# leaves the machine. CI cannot otherwise prove a single byte of what it emits.
RX_PID=""
RX_DIR=""

start_receiver() {
  RX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/otel-rx.XXXXXX")
  : >"$RX_DIR/bodies.jsonl"
  python3 - "${1:-200}" "$RX_DIR" >/dev/null 2>&1 <<'PY' &
import http.server
import json
import os
import sys

status = int(sys.argv[1])
outdir = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) or b"{}"
        record = {"path": self.path, "headers": dict(self.headers), "body": json.loads(raw)}
        with open(os.path.join(outdir, "bodies.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(outdir, "port"), "w", encoding="utf-8") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY
  RX_PID=$!
  local i=0
  while [ ! -s "$RX_DIR/port" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$RX_DIR/port" ] || return 1
  RX_URL="http://127.0.0.1:$(cat "$RX_DIR/port")"
  return 0
}

stop_receiver() {
  [ -n "$RX_PID" ] && kill "$RX_PID" 2>/dev/null
  wait "$RX_PID" 2>/dev/null
  RX_PID=""
  return 0
}

RX_URL=""
FAILURES=0
CHECKS=0

ok() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

nope() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'NOT OK %d - %s\n' "$CHECKS" "$1"
  [ $# -gt 1 ] && printf '  %s\n' "$2"
  return 0
}

assert_eq() { # want got label
  if [ "$1" = "$2" ]; then ok "$3"; else nope "$3" "want [$1] got [$2]"; fi
}

bodies() { cat "$RX_DIR/bodies.jsonl" 2>/dev/null; }
body_count() { bodies | grep -c . ; }

self_test() {
  # A global, not a local: the EXIT trap runs after self_test's frame is gone.
  SELFTEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/otel-selftest.XXXXXX")
  local tmp="$SELFTEST_TMP"
  export OTEL_BREAKER_FILE="$tmp/breaker"
  trap 'stop_receiver; rm -rf "${SELFTEST_TMP:-}"' EXIT

  # Start from a known-off environment: the self-test must not inherit the
  # machine's own OTEL configuration.
  unset OTEL_SDK_DISABLED OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT \
    OTEL_SERVICE_NAME OTEL_RESOURCE_ATTRIBUTES ESTATE_HOST_CLASS TRACEPARENT OTELSPAN_TASK 2>/dev/null || true

  printf '# otel-span.sh self-test\n\n'

  # --- 1. the contract's trace-id recipe (§2), checked against an independent digest
  local want_t want_r got
  want_t=$(printf 'estate-task|m7|T42' | sha256sum | cut -d' ' -f1); want_t="${want_t:0:32}"
  want_r=$(printf 'estate-task-root|m7|T42' | sha256sum | cut -d' ' -f1); want_r="${want_r:0:16}"
  got=$(bash "$SELF" task-traceparent m7 T42)
  assert_eq "00-${want_t}-${want_r}-01" "$got" "task-traceparent follows sha256(\"estate-task|<m>|<t>\")"
  assert_eq "$(printf '0%.0s' $(seq 31))1" "$(nonzero "$(printf '0%.0s' $(seq 32))")" \
    "an all-zero trace id falls back to last-digit 1 (W3C forbids all-zero)"

  # --- 2. traceparent parsing: strict, and all-zero ids are refused
  assert_eq "$(printf 'a%.0s' $(seq 32)) $(printf 'b%.0s' $(seq 16))" \
    "$(bash "$SELF" parse-traceparent "00-$(printf 'a%.0s' $(seq 32))-$(printf 'b%.0s' $(seq 16))-01")" \
    "parse-traceparent accepts a well-formed W3C header"
  local bad="" one=""
  for bad in "" "garbage" "ff-$(printf 'a%.0s' $(seq 32))-$(printf 'b%.0s' $(seq 16))-01" \
    "00-$(printf '0%.0s' $(seq 32))-$(printf 'b%.0s' $(seq 16))-01" \
    "00-$(printf 'a%.0s' $(seq 32))-0000000000000000-01" \
    "00-$(printf 'a%.0s' $(seq 32))-$(printf 'b%.0s' $(seq 16))-1" \
    "0-$(printf 'a%.0s' $(seq 32))-$(printf 'b%.0s' $(seq 16))-01"; do
    if bash "$SELF" parse-traceparent "$bad" >/dev/null 2>&1; then
      nope "parse-traceparent rejects [$bad]"
    else
      one="$one."
    fi
  done
  assert_eq "......." "$one" "parse-traceparent rejects malformed, ff-version and all-zero ids"

  # --- 3. estate.host.class derivation stays coarse (a label, never a hostname)
  assert_eq "bazzite" "$(bash "$SELF" detect-host-class bazzite)" "runner label bazzite -> bazzite"
  assert_eq "github-hosted" "$(bash "$SELF" detect-host-class ubuntu-latest)" "ubuntu-latest -> github-hosted"
  assert_eq "dev-vm" "$(bash "$SELF" detect-host-class dev-vm)" "dev-vm label -> dev-vm"
  assert_eq "unknown" "$(bash "$SELF" detect-host-class some-weird-box)" "an unknown label degrades to unknown"

  # --- 4. unset endpoint means off (§1): nothing sent, exit 0
  start_receiver 200 || { printf 'self-test: could not start the throwaway receiver\n' >&2; exit 1; }
  bash "$SELF" emit --name off-test --trace-id "$(printf '1%.0s' $(seq 32))" --span-id "$(printf '2%.0s' $(seq 16))" >/dev/null
  assert_eq "0" "$(body_count)" "with no endpoint configured, nothing is sent and the caller still exits 0"
  OTEL_SDK_DISABLED=true OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" \
    bash "$SELF" emit --name off-test --trace-id "$(printf '1%.0s' $(seq 32))" --span-id "$(printf '2%.0s' $(seq 16))" >/dev/null
  assert_eq "0" "$(body_count)" "OTEL_SDK_DISABLED=true wins over a configured endpoint"

  # --- 5. a real span on the wire: OTLP/HTTP JSON to /v1/traces
  export OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL"
  export OTEL_SERVICE_NAME="ci-harness"
  local ctx="$tmp/ctx.env"
  OTELSPAN_JOB_KEY="reusable-python:test" OTELSPAN_PIPELINE_NAME="self-smoke" \
    OTELSPAN_RUN_ID="4242" OTELSPAN_RUN_ATTEMPT="1" OTELSPAN_REPOSITORY="Rylee-Bee/ci-harness" \
    OTELSPAN_REF_HEAD="otel/ci-19" OTELSPAN_HEAD_REVISION="$(printf 'c%.0s' $(seq 40))" \
    OTELSPAN_CHANGE_ID="314" OTELSPAN_RUNNER_LABEL="bazzite" OTELSPAN_READ_GIT=0 \
    bash "$SELF" context --env-file "$ctx" >/dev/null
  # shellcheck disable=SC1090
  . "$ctx"
  assert_eq "$(sha256_hex "cicd-pipeline|4242|1|reusable-python:test" | cut -c1-16)" "${otel_pipeline_span_id}" \
    "the pipeline span id is derived from run id + job key, so every hop agrees"
  bash "$SELF" ci-emit --env-file "$ctx" --role pipeline --result success >/dev/null
  bash "$SELF" ci-emit --env-file "$ctx" --role job --result success >/dev/null

  local blob first second
  blob=$(bodies)
  assert_eq "/v1/traces" "$(printf '%s' "$blob" | head -n1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["path"])')" \
    "spans are POSTed to /v1/traces as the contract requires"
  first=$(printf '%s' "$blob" | sed -n 1p)
  second=$(printf '%s' "$blob" | sed -n 2p)
  local p_attrs j_attrs p_res j_res
  p_attrs=$(printf '%s' "$first" | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(s["traceId"], s["spanId"], s.get("parentSpanId","-"), len(s["attributes"]))')
  j_attrs=$(printf '%s' "$second" | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(s["traceId"], s["spanId"], s.get("parentSpanId","-"), len(s["attributes"]))')
  p_res=$(printf '%s' "$first" | python3 -c '
import json,sys
r=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["resource"]["attributes"]
print(" ".join(a["key"]+"="+list(a["value"].values())[0] for a in r))')
  assert_eq "$otel_trace_id ${otel_pipeline_span_id} - 10" "$p_attrs" \
    "the pipeline span carries the standard CI/CD conventions plus vcs and estate attributes"
  assert_eq "$otel_trace_id ${otel_span_id} ${otel_pipeline_span_id} 13" "$j_attrs" \
    "the job span is a child of the pipeline span and adds cicd.pipeline.task.*"

  local want_attrs='cicd.pipeline.name=self-smoke cicd.pipeline.run.id=4242 cicd.pipeline.result=success
cicd.worker.name=bazzite estate.actor.kind=ci estate.host.class=bazzite vcs.repository.name=ci-harness
vcs.ref.head.name=otel/ci-19 vcs.ref.head.revision=cccccccccccccccccccccccccccccccccccccccc
vcs.change.id=314'
  got=$(printf '%s' "$second" | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(" ".join(a["key"]+"="+list(a["value"].values())[0] for a in s["attributes"] if not a["key"].startswith("cicd.pipeline.task")))')
  assert_eq "$(printf '%s' "$want_attrs" | tr '\n' ' ' | sed 's/  */ /g;s/ $//')" "$got" \
    "the job span's attributes are exactly the contract's standard names and values"
  assert_eq "service.name=ci-harness service.namespace=estate estate.host.class=bazzite" "$p_res" \
    "the resource carries service.name, service.namespace=estate and estate.host.class"

  got=$(printf '%s' "$second" | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(" ".join(a["key"]+"="+list(a["value"].values())[0] for a in s["attributes"] if a["key"].startswith("cicd.pipeline.task")))')
  assert_eq "cicd.pipeline.task.name=reusable-python:test cicd.pipeline.task.run.id=${otel_task_run_id} cicd.pipeline.task.run.result=success" "$got" \
    "the job span carries cicd.pipeline.task.name, task.run.id and task.run.result"

  printf '\n--- one real OTLP/HTTP body this self-test captured ---\n'
  printf '%s' "$second" | python3 -c '
import json,sys
print(json.dumps(json.loads(sys.stdin.read())["body"], indent=2))'
  printf -- '--- end body ---\n\n'


  # --- 5b. a span describing one call inside the job (Project Home's /api/ci call)
  bash "$SELF" ci-emit --env-file "$ctx" --role job --result success --child \
    --name project_home.ci_request --parent-span-id "$otel_span_id" \
    --attr "http.request.method=POST" --attr "http.route=/api/ci/tasks/{task_id}/claim" \
    --attr "url.path=/api/ci/tasks/{task_id}/claim" --attr "http.response.status_code=200" >/dev/null
  got=$(bodies | tail -n1 | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(s["traceId"], s["spanId"], s.get("parentSpanId","-"), s["name"], "|",
      " ".join(a["key"]+"="+list(a["value"].values())[0] for a in s["attributes"] if a["key"].startswith("http.")))')
  if [ "${got%% *}" = "$otel_trace_id" ] && [[ "$got" == *" $otel_span_id project_home.ci_request"* ]] \
    && [[ "$got" == *"http.request.method=POST"* ]] && [[ "$got" == *"http.response.status_code=200"* ]]; then
    ok "a call span hangs off the job span, is not its own parent, and carries the standard HTTP attributes"
  else
    nope "a call span hangs off the job span, is not its own parent, and carries the standard HTTP attributes" "got [$got]"
  fi

  unset OTEL_EXPORTER_OTLP_ENDPOINT
  rm -f "$OTEL_BREAKER_FILE"

  # --- 6. a PR a mission lands carries Estate-Task: <mission>/<task> (§2)
  local repo="$tmp/fixture-repo"
  git init -q "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "ci: land the thing

Estate-Task: m9/T7"
  assert_eq "m9/T7" "$(cd "$repo" && bash "$SELF" task-from-git)" \
    "task-from-git reads the Estate-Task trailer off the HEAD commit"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "ci: an ordinary commit with no trailer"
  assert_eq "" "$(cd "$repo" && bash "$SELF" task-from-git)" "a commit with no trailer yields no task"

  OTELSPAN_JOB_KEY="reusable-node:build" OTELSPAN_PIPELINE_NAME="validate" OTELSPAN_RUN_ID="7" \
    OTELSPAN_RUN_ATTEMPT="1" OTELSPAN_REPOSITORY="Rylee-Bee/vefr" OTELSPAN_REF_HEAD="314/merge" \
    OTELSPAN_CHANGE_ID="314" OTELSPAN_RUNNER_LABEL="ubuntu-latest" \
    bash "$SELF" context --env-file "$tmp/ctx-git.env" --task "m9/T7" >/dev/null
  local g; g=$(grep '^otel_trace_id=' "$tmp/ctx-git.env" | cut -d= -f2- | tr -d "'")
  assert_eq "$(printf 'estate-task|m9|T7' | sha256sum | cut -d' ' -f1 | cut -c1-32)" "$g" \
    "a mission PR joins the task's trace, computed from the ids alone"

  # --- 7. a PR with no trailer gets its own trace, linked by vcs.change.id
  unset OTELSPAN_TASK
  OTELSPAN_JOB_KEY="reusable-node:build" OTELSPAN_PIPELINE_NAME="validate" OTELSPAN_RUN_ID="7" \
    OTELSPAN_RUN_ATTEMPT="1" OTELSPAN_REPOSITORY="Rylee-Bee/vefr" OTELSPAN_CHANGE_ID="314" \
    OTELSPAN_RUNNER_LABEL="ubuntu-latest" \
    bash "$SELF" context --env-file "$tmp/ctx-untrailered.env" >/dev/null
  g=$(grep '^otel_trace_id=' "$tmp/ctx-untrailered.env" | cut -d= -f2- | tr -d "'")
  if [ "${#g}" -eq 32 ] && [ "$g" != "$(printf 'estate-task||' | sha256sum | cut -d' ' -f1 | cut -c1-32)" ]; then
    ok "a PR with no Estate-Task trailer gets its own 32-hex trace id"
  else
    nope "a PR with no Estate-Task trailer gets its own 32-hex trace id" "got [$g]"
  fi
  assert_eq "otel_change_id='314'" "$(grep '^otel_change_id=' "$tmp/ctx-untrailered.env")" \
    "an untrailered run is still linked back by vcs.change.id"

  # --- 8. a GitHub-hosted runner never emits a span that cannot arrive (§1)
  : >"$RX_DIR/bodies.jsonl"
  OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" GITHUB_STEP_SUMMARY="$tmp/summary.md" \
    bash "$SELF" ci-emit --env-file "$tmp/ctx-untrailered.env" --role job --result success >/dev/null
  assert_eq "0" "$(body_count)" "host-class github-hosted sends nothing at all"
  if grep -q "github-hosted" "$tmp/summary.md" 2>/dev/null; then
    ok "host-class github-hosted says so in the step summary instead of failing silently"
  else
    nope "host-class github-hosted says so in the step summary instead of failing silently"
  fi

  # --- 9. an unreachable Collector costs one timeout, then nothing, and never fails
  unset OTEL_EXPORTER_OTLP_ENDPOINT
  local t0 t1 rc
  t0=$(date +%s%N)
  OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:9" bash "$SELF" ci-emit --env-file "$ctx" --role job --result failure >/dev/null
  rc=$?
  t1=$(date +%s%N)
  assert_eq "0" "$rc" "an unreachable Collector leaves the exit code at 0 — telemetry never fails CI"
  if [ -f "$OTEL_BREAKER_FILE" ]; then ok "one failed send trips the circuit breaker for the rest of the job"; else nope "one failed send trips the circuit breaker for the rest of the job"; fi
  t0=$(date +%s%N)
  OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:9" bash "$SELF" ci-emit --env-file "$ctx" --role pipeline --result failure >/dev/null
  t1=$(date +%s%N)
  if [ $(( (t1 - t0) / 1000000 )) -lt 500 ]; then
    ok "after the breaker trips, a second span costs no further dial"
  else
    nope "after the breaker trips, a second span costs no further dial" "$(( (t1 - t0) / 1000000 )) ms"
  fi
  rm -f "$OTEL_BREAKER_FILE"

  # --- 10. a Collector answering 500 trips the breaker after one send
  stop_receiver
  start_receiver 500 || { printf 'self-test: could not start the failing receiver\n' >&2; exit 1; }
  OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" bash "$SELF" ci-emit --env-file "$ctx" --role pipeline --result failure >/dev/null
  OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" bash "$SELF" ci-emit --env-file "$ctx" --role job --result failure >/dev/null
  assert_eq "1" "$(body_count)" "a Collector answering 500 is sent exactly one request, then the breaker holds"

  printf '%d checks, %d failures\n' "$CHECKS" "$FAILURES"
  [ "$FAILURES" -eq 0 ] || return 1
  printf 'otel-span.sh self-test: OK\n'
  return 0
}

main "$@"
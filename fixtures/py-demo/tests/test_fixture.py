"""Minimal honest fixture: proves sync + pytest wiring, nothing more."""


def test_arithmetic_is_deterministic() -> None:
    assert sum([1, 2, 3]) == 6

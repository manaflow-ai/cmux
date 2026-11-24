from pytest_shim import raises
from envexpand import UnsetVariable, expand, expand_all, expand_env, parse_dotenv, resolve_workspace

ENV = {"HOME": "/home/me", "EMPTY": "", "EDITOR": "vim"}


def unset_name(fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except UnsetVariable as e:
        return e.name
    raise AssertionError("did not raise UnsetVariable")


def test_reported_braced_reference_is_strict():
    assert unset_name(expand, "--token=${API_TOKEN}", ENV, strict=True) == "API_TOKEN"
    assert unset_name(expand, "--token=$API_TOKEN", ENV, strict=True) == "API_TOKEN"
    assert expand("--token=${API_TOKEN}", ENV) == "--token="


def test_strict_allows_set_and_empty():
    assert expand("${HOME}/x:$EMPTY:${EMPTY}", ENV, strict=True) == "/home/me/x::"
    assert expand("${EMPTY-dflt}|${EMPTY:-dflt}", ENV, strict=True) == "|dflt"


def test_used_default_is_strict_too():
    assert unset_name(expand, "${NOPE:-$ALSO_NOPE}", ENV, strict=True) == "ALSO_NOPE"
    assert unset_name(expand, "${NOPE-${INNER}}", ENV, strict=True) == "INNER"
    assert unset_name(expand, "${EMPTY:-${INNER:-$DEEP}}", ENV, strict=True) == "DEEP"
    assert expand("${NOPE:-${EDITOR}}", ENV, strict=True) == "vim"


def test_unused_default_is_not_evaluated():
    assert expand("${EDITOR:-$MISSING}", ENV, strict=True) == "vim"
    assert expand("${EMPTY-${MISSING}}", ENV, strict=True) == ""
    assert expand("${HOME:-${A:-${B}}}", ENV, strict=True) == "/home/me"


def test_dotenv_and_env_blocks_are_strict():
    assert unset_name(parse_dotenv, "A=1\nB=\"$A/${NOPE}\"\n", ENV, strict=True) == "NOPE"
    assert unset_name(parse_dotenv, "B=$NOPE\n", ENV, strict=True) == "NOPE"
    assert parse_dotenv("A=1\nB='${NOPE}'\nC=$A$EMPTY\n", ENV, strict=True) == {"A": "1", "B": "${NOPE}", "C": "1"}
    assert unset_name(expand_env, {"X": "${NOPE}"}, ENV, strict=True) == "NOPE"
    assert unset_name(expand_all, ["ok", "${NOPE}"], ENV, strict=True) == "NOPE"


def test_workspace_strict_everywhere():
    cfg = {"env": {"ROOT": "$HOME/src"}, "cwd": "${ROOT}/${PROJECT}", "command": ["run"]}
    assert unset_name(resolve_workspace, cfg, ENV, strict=True) == "PROJECT"
    cfg = {"env": {"ROOT": "$HOME/src"}, "cwd": "${ROOT}", "command": ["$EDITOR", "${FILE}"]}
    assert unset_name(resolve_workspace, cfg, ENV, strict=True) == "FILE"
    cfg["command"] = ["$EDITOR", "${FILE:-README}"]
    assert resolve_workspace(cfg, ENV, strict=True) == {
        "env": {"ROOT": "/home/me/src"}, "cwd": "/home/me/src", "command": ["vim", "README"]}


def test_non_strict_regressions():
    assert expand("$NOPE|${NOPE}|${NOPE:-$HOME}|${EMPTY-x}|${EMPTY:-x}", ENV) == "||/home/me||x"
    assert expand("cost: \\$5, $ alone, $1, ${EDITOR:-${VISUAL:-vi}}", ENV) == "cost: $5, $ alone, $1, vim"
    assert expand("${A:-${B:-deep}}", {}) == "deep"
    assert expand("$HOME_DIR/$HOME", {"HOME": "h", "HOME_DIR": "hd"}) == "hd/h"
    raises(ValueError, expand, "${HOME", ENV)
    raises(ValueError, expand, "${HOME:+x}", ENV)


def test_dotenv_regressions():
    src = "# comment\n\nexport A=one\nB = \"$A two\"\nC='$A lit'\nD=$C\n"
    assert parse_dotenv(src, {}) == {"A": "one", "B": "one two", "C": "$A lit", "D": "$A lit"}
    raises(ValueError, parse_dotenv, "not a line\n", {})
    assert expand_env({"A": "x", "B": "$A/y", "HOME": "$HOME!"}, ENV) == {"A": "x", "B": "x/y", "HOME": "/home/me!"}

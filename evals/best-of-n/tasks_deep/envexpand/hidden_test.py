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


class Unset(Exception):
    pass


def gen(rnd, depth):
    nodes = []
    for _ in range(rnd.randint(0, 4)):
        roll = rnd.random()
        name = rnd.choice(["A", "B", "EMPTY", "NOPE", "Q_1"])
        if roll < 0.2:
            nodes.append(("lit", rnd.choice(["/", ".", " ", ":", "-x", "/y.", ":-"])))
        elif roll < 0.3:
            nodes.append(("lit_out", rnd.choice(["\\$", "$1", "$ ", "$/"])))
        elif roll < 0.5:
            nodes.append(("var", name, rnd.random() < 0.5))
        elif depth < 3:
            nodes.append(("dflt", name, rnd.random() < 0.5, gen(rnd, depth + 1)))
        else:
            nodes.append(("var", name, True))
    return nodes


def render(nodes):
    out = []
    for n in nodes:
        if n[0] in ("lit", "lit_out"):
            out.append(n[1])
        elif n[0] == "var":
            out.append("${%s}" % n[1] if n[2] else "$" + n[1])
        else:
            out.append("${%s%s%s}" % (n[1], ":-" if n[2] else "-", render(n[3])))
        if n[0] == "var" and not n[2]:
            out.append("/")
    return "".join(out)


def model(nodes, env, strict):
    out = []
    for n in nodes:
        if n[0] == "lit":
            out.append(n[1])
        elif n[0] == "lit_out":
            out.append(n[1].replace("\\$", "$"))
        elif n[0] == "var":
            if n[1] not in env and strict:
                raise Unset(n[1])
            out.append(env.get(n[1], ""))
        else:
            value = env.get(n[1], "")
            use = (not value) if n[2] else (n[1] not in env)
            out.append(model(n[3], env, strict) if use else env[n[1]])
        if n[0] == "var" and not n[2]:
            out.append("/")
    return "".join(out)


def test_random_templates_match_model():
    import random
    rnd = random.Random(8)
    envs = [{"A": "a", "B": "", "EMPTY": ""}, {"A": "", "NOPE": "n"}, {"B": "b", "Q_1": "q"}, {}]
    for _ in range(2000):
        tree = gen(rnd, 0)
        text = render(tree)
        env = rnd.choice(envs)
        assert expand(text, env) == model(tree, env, False), (text, env)
        try:
            want = model(tree, env, True)
        except Unset as e:
            assert unset_name(expand, text, env, strict=True) == e.args[0], (text, env)
            assert unset_name(expand_all, ["x", text], env, strict=True) == e.args[0], (text, env)
        else:
            assert expand(text, env, strict=True) == want, (text, env)
            assert expand_all([text, text], env, strict=True) == [want, want]


def test_escapes_inside_defaults_regressions():
    assert expand("${NOPE:-\\$HOME}", ENV, strict=True) == "$HOME"
    assert expand("${NOPE-a\\}b}", ENV) == "a\\}b"
    raises(ValueError, expand, "${EDITOR:-\\}", ENV)
    assert expand("trailing \\ and $", ENV, strict=True) == "trailing \\ and $"
    raises(ValueError, expand, "${}", ENV)
    raises(ValueError, expand, "${1A}", ENV)

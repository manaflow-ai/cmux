from keyring import Settings

DEFAULTS = {
    "theme": "dark",
    "terminal": {"font": {"family": "Menlo", "size": 13}, "scrollback": 10000, "bell": True, "ratio": 0.5},
    "keys": [{"id": "split", "chord": "cmd+d", "when": {"focus": "pane"}}, {"id": "close", "chord": "cmd+w"}],
    "paths": ["/usr/bin"],
}
USER = {"terminal": {"font": {"family": "Iosevka", "size": 14}}}


def test_reported_nested_null_falls_through():
    s = Settings(DEFAULTS, USER, {"terminal": {"font": {"size": None}}})
    assert s.get("terminal.font.size") == 14
    assert s.get("terminal.font.family") == "Iosevka"


def test_top_level_and_section_null():
    s = Settings(DEFAULTS, {"theme": "light"}, {"theme": None, "terminal": None})
    assert s.get("theme") == "light"
    assert s.get("terminal.font.size") == 13


def test_null_in_a_new_section_is_absent():
    s = Settings(DEFAULTS, {"agent": {"model": "opus", "effort": None, "limits": {"turns": None}}})
    assert s.get("agent.model") == "opus"
    assert s.get("agent.effort", "unset") == "unset"
    d = s.as_dict()
    assert "effort" not in d["agent"]
    assert d["agent"].get("limits", {}) == {} or "turns" not in d["agent"]["limits"]


def test_null_replacing_scalar_with_object():
    s = Settings({"proxy": "off"}, {"proxy": {"host": "h", "port": None}})
    assert s.get("proxy") == {"host": "h"}


def test_keyed_list_items_merge_like_objects():
    ws = {"keys": [{"id": "split", "chord": None, "when": {"mode": "vim"}}, {"id": "new", "chord": "cmd+t",
                                                                            "when": None}]}
    s = Settings(DEFAULTS, USER, ws)
    keys = s.get("keys")
    assert [k["id"] for k in keys] == ["split", "close", "new"]
    assert keys[0] == {"id": "split", "chord": "cmd+d", "when": {"focus": "pane", "mode": "vim"}}
    assert keys[1] == {"id": "close", "chord": "cmd+w"}
    assert keys[2] == {"id": "new", "chord": "cmd+t"}


def test_plain_lists_replace_and_keyed_order():
    s = Settings(DEFAULTS, {"paths": ["/opt/bin"], "keys": [{"id": "zz", "chord": "x"}, {"id": "close",
                                                                                          "chord": "cmd+q"}]})
    assert s.get("paths") == ["/opt/bin"]
    assert [k["id"] for k in s.get("keys")] == ["split", "close", "zz"]
    assert s.get("keys")[1]["chord"] == "cmd+q"


def test_empty_env_var_is_unset():
    env = {"CMUX_TERMINAL__FONT__SIZE": "", "CMUX_THEME": "", "CMUX_NEWKEY": ""}
    s = Settings(DEFAULTS, USER, {}, env)
    assert s.get("terminal.font.size") == 14
    assert s.get("theme") == "dark"
    assert s.get("newkey", "none") == "none"
    assert s.warnings == []


def test_env_converts_by_type_below():
    env = {"CMUX_TERMINAL__FONT__SIZE": "16", "CMUX_TERMINAL__BELL": "Off", "CMUX_TERMINAL__RATIO": "0.25",
           "CMUX_PATHS": '["/a", "/b"]', "CMUX_FRESH": "12", "OTHER": "1", "CMUX_": "x"}
    s = Settings(DEFAULTS, USER, {}, env)
    assert s.get("terminal.font.size") == 16
    assert s.get("terminal.bell") is False
    assert s.get("terminal.ratio") == 0.25
    assert s.get("paths") == ["/a", "/b"]
    assert s.get("fresh") == "12"
    assert s.warnings == []


def test_env_bad_value_is_ignored_with_warning():
    s = Settings(DEFAULTS, USER, {}, {"CMUX_TERMINAL__SCROLLBACK": "lots"})
    assert s.get("terminal.scrollback") == 10000
    assert len(s.warnings) == 1


def test_get_returns_copies_and_inputs_untouched():
    ws = {"keys": [{"id": "split", "chord": None}], "terminal": {"font": {"size": None}}}
    s = Settings(DEFAULTS, USER, ws)
    keys = s.get("keys")
    keys.append({"id": "evil"})
    keys[0]["chord"] = "x"
    assert [k["id"] for k in s.get("keys")] == ["split", "close"]
    assert s.get("keys")[0]["chord"] == "cmd+d"
    assert ws == {"keys": [{"id": "split", "chord": None}], "terminal": {"font": {"size": None}}}
    assert DEFAULTS["keys"][0] == {"id": "split", "chord": "cmd+d", "when": {"focus": "pane"}}
    assert s.get("missing.key", 7) == 7


def test_nulls_inside_plain_lists():
    s = Settings({"paths": ["/usr/bin"]}, {"paths": ["/a", None], "servers": [{"host": "h", "port": None}, 3]})
    assert s.get("paths") == ["/a", None]
    assert s.get("servers") == [{"host": "h"}, 3]


def test_env_converts_against_value_below_a_null():
    s = Settings(DEFAULTS, {"terminal": {"font": {"size": None}}}, {"terminal": None},
                 {"CMUX_TERMINAL__FONT__SIZE": "16", "CMUX_TERMINAL__BELL": "YES"})
    assert s.get("terminal.font.size") == 16 and s.get("terminal.bell") is True


def _model(layers):
    """Reference resolver for random trees: dict merge, keyed lists merge by id, nulls unset."""
    def clean(v):
        if isinstance(v, dict):
            return {k: clean(x) for k, x in v.items() if x is not None}
        if isinstance(v, list):
            return [clean(x) for x in v]
        return v

    def keyed(v):
        return isinstance(v, list) and v and all(isinstance(x, dict) and "id" in x for x in v)

    def over(lo, hi):
        if isinstance(lo, dict) and isinstance(hi, dict):
            out = dict(lo)
            for k, v in hi.items():
                if v is not None:
                    out[k] = over(out[k], v) if k in out else clean(v)
            return out
        if keyed(lo) and keyed(hi):
            out = list(lo)
            for item in hi:
                ids = [x["id"] for x in out]
                if item["id"] in ids:
                    i = ids.index(item["id"])
                    out[i] = over(out[i], item)
                else:
                    out.append(clean(item))
            return out
        return clean(hi)

    acc = {}
    for layer in layers:
        acc = over(acc, layer)
    return acc


def test_random_layers_match_model():
    import random
    rng = random.Random(3)

    def value(depth):
        roll = rng.random()
        if depth > 2 or roll < 0.3:
            return rng.choice([None, None, 1, "s", True, 2.5])
        if roll < 0.7:
            return {k: value(depth + 1) for k in rng.sample("abcd", rng.randint(1, 3))}
        if roll < 0.85:
            return [dict({"id": i}, **{k: value(depth + 2) for k in rng.sample("xy", rng.randint(0, 2))})
                    for i in rng.sample(range(4), rng.randint(1, 3))]
        return [rng.choice([1, None, "z"]) for _ in range(rng.randint(0, 3))]

    for _ in range(300):
        layers = [{k: value(1) for k in rng.sample("pqr", rng.randint(0, 3))} for _ in range(3)]
        s = Settings(*layers)
        assert s.as_dict() == _model(layers), layers

"""Layered settings for cmux.

A setting's value comes from four layers, lowest first: built-in defaults, the user's settings file, the
workspace's settings file, and the environment. Each file layer is a JSON object; nested objects are sections
("terminal": {"font": {"size": 13}}) and a dotted key names a nested setting ("terminal.font.size").

Merging a higher layer over a lower one: objects merge key by key, recursively. A list whose items are all objects
with an "id" key is a keyed list: it merges item by item, matching ids (items in the lower layer keep their order,
new ids are appended in the higher layer's order). Any other list, and any scalar, replaces the lower value.

The environment layer is the variables named CMUX_<PATH>, where PATH is the dotted key upper-cased with "." written
as "__" (CMUX_TERMINAL__FONT__SIZE is terminal.font.size). A value is converted to the type the key has in the
layers below: int, float, bool ("1", "true", "yes", "on" or "0", "false", "no", "off", any case) or a list (JSON);
a key with no value below stays a string. A value that does not convert is ignored, with a warning.
"""
from __future__ import annotations

import copy
import json

TRUE = {"1", "true", "yes", "on"}
FALSE = {"0", "false", "no", "off"}
PREFIX = "CMUX_"


def is_keyed_list(value) -> bool:
    return isinstance(value, list) and bool(value) and all(isinstance(v, dict) and "id" in v for v in value)


def _merge_dict(lower: dict, higher: dict) -> dict:
    out = dict(lower)
    for key, value in higher.items():
        if value is None:
            continue
        out[key] = merge(out[key], value) if key in out else copy.deepcopy(value)
    return out


def _merge_keyed(lower: list, higher: list) -> list:
    out = [dict(item) for item in lower]
    index = {item["id"]: i for i, item in enumerate(out)}
    for item in higher:
        if item["id"] in index:
            i = index[item["id"]]
            out[i] = {**out[i], **item}
        else:
            index[item["id"]] = len(out)
            out.append(copy.deepcopy(item))
    return out


def merge(lower, higher):
    """`higher` merged over `lower` (neither is changed)."""
    if isinstance(lower, dict) and isinstance(higher, dict):
        return _merge_dict(lower, higher)
    if is_keyed_list(lower) and is_keyed_list(higher):
        return _merge_keyed(lower, higher)
    return copy.deepcopy(higher)


def lookup(tree: dict, key: str, missing=None):
    node = tree
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            return missing
        node = node[part]
    return node


def convert(raw: str, like):
    """`raw` converted to the type of `like`; ValueError if it does not convert."""
    if isinstance(like, bool):
        word = raw.strip().lower()
        if word in TRUE:
            return True
        if word in FALSE:
            return False
        raise ValueError(raw)
    if isinstance(like, int):
        return int(raw)
    if isinstance(like, float):
        return float(raw)
    if isinstance(like, list):
        value = json.loads(raw)
        if not isinstance(value, list):
            raise ValueError(raw)
        return value
    return raw


def env_layer(environ: dict, below: dict, warnings: list) -> dict:
    """The environment's settings as a nested object, converted against `below` (the merged lower layers)."""
    layer: dict = {}
    for name in sorted(environ):
        if not name.startswith(PREFIX) or len(name) == len(PREFIX):
            continue
        key = name[len(PREFIX):].lower().replace("__", ".")
        like = lookup(below, key)
        raw = environ[name]
        try:
            value = raw if like is None else convert(raw, like)
        except ValueError:
            warnings.append(f"{name}: cannot use {raw!r} for {key}")
            continue
        node = layer
        parts = key.split(".")
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = value
    return layer


class Settings:
    def __init__(self, defaults: dict, user: dict | None = None, workspace: dict | None = None,
                 environ: dict | None = None):
        self.warnings: list[str] = []
        resolved: dict = {}
        for layer in (defaults, user or {}, workspace or {}):
            for key, value in layer.items():
                if value is None:
                    continue
                resolved[key] = merge(resolved[key], value) if key in resolved else copy.deepcopy(value)
        env = env_layer(environ or {}, resolved, self.warnings)
        self._resolved = merge(resolved, env)

    def get(self, key: str, default=None):
        """The resolved value of a dotted key, or `default` when no layer sets it. The caller gets its own copy:
        changing a returned list or object never changes the settings."""
        value = lookup(self._resolved, key, missing=default)
        return copy.deepcopy(value)

    def as_dict(self) -> dict:
        return copy.deepcopy(self._resolved)

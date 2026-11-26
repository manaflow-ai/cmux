"""DeterministicJSON (CmuxNextSettings/Schema/DeterministicJSON.swift) in Python.

The same bytes as the Swift writer: `"key" : value`, two-space indent, keys in
case-insensitive order with ties broken by exact scalar order, unescaped
slashes and non-ASCII, an empty container as open line, blank line, close, and
every number in its shortest round-trip form (whole numbers below 1e15 with no
fraction, exponents without sign padding).
"""
import math


def number(value):
    if isinstance(value, bool):
        raise TypeError("bool is not a number")
    if isinstance(value, int):
        return str(value)
    if not math.isfinite(value):
        raise ValueError("JSON has no form for NaN or infinity")
    if value == round(value) and abs(value) < 1e15:
        return str(int(value))
    text = repr(value)
    if "e" in text or "E" in text:
        mantissa, exponent = text.lower().split("e")
        return "%se%d" % (mantissa, int(exponent))
    return text


def key_order(key):
    return (key.lower(), key)


def quote(text):
    out = ['"']
    for ch in text:
        code = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\b":
            out.append("\\b")
        elif ch == "\f":
            out.append("\\f")
        elif code < 0x20:
            out.append("\\u%04x" % code)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def dumps(value, pretty=True, indent=0):
    if isinstance(value, str):
        return quote(value)
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return number(value)
    if isinstance(value, dict):
        keys = sorted(value, key=key_order)
        items = [quote(k) + (" : " if pretty else ":") + dumps(value[k], pretty, indent + 1) for k in keys]
        return container("{", "}", items, pretty, indent)
    if isinstance(value, (list, tuple)):
        return container("[", "]", [dumps(v, pretty, indent + 1) for v in value], pretty, indent)
    raise TypeError("unsupported value %r" % type(value).__name__)


def container(open_, close, items, pretty, indent):
    out = open_
    inner = "  " * (indent + 1)
    for index, item in enumerate(items):
        if index:
            out += ","
        if pretty:
            out += "\n" + inner
        out += item
    if pretty:
        out += ("\n\n" if not items else "\n") + "  " * indent
    return out + close

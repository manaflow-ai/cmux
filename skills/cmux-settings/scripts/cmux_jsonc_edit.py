"""Minimal JSONC path mutation helpers for cmux.json set/unset operations."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any


class JSONCEditError(ValueError):
    pass


@dataclass(frozen=True)
class PropertyRange:
    key: str
    key_start: int
    value_start: int
    value_end: int


@dataclass(frozen=True)
class ObjectRange:
    open_brace: int
    close_brace: int
    properties: tuple[PropertyRange, ...]

    def property(self, key: str) -> PropertyRange | None:
        # Match json.loads/Foundation duplicate-key semantics: the last
        # occurrence is the effective value and therefore the mutation target.
        return next(
            (item for item in reversed(self.properties) if item.key == key),
            None,
        )


def set_jsonc_path(source: str, parts: list[str], value: Any) -> str:
    """Set one object path while retaining source text outside the target."""
    if not parts:
        raise JSONCEditError("empty JSON path")
    root = _root_object(source)
    if root is None:
        raise JSONCEditError("top-level JSONC value is not an editable object")
    return _setting(source, root, parts, value)


def remove_jsonc_path(source: str, parts: list[str]) -> str:
    """Remove one object path, pruning plain empty parents."""
    if not parts:
        raise JSONCEditError("empty JSON path")
    if _root_object(source) is None:
        raise JSONCEditError("top-level JSONC value is not an editable object")
    if _parent_and_property_index(source, parts) is None:
        return source

    updated = source
    # Parsed JSON resolves duplicate keys to the last occurrence. Remove every
    # duplicate leaf so unset cannot expose a shadowed value.
    while _parent_and_property_index(updated, parts) is not None:
        updated = _remove_property(updated, parts)

    for depth in range(len(parts) - 1, 0, -1):
        ancestor = parts[:depth]
        obj = _object_at_path(updated, ancestor)
        found = _parent_and_property_index(updated, ancestor)
        if (
            obj is None
            or obj.properties
            or _contains_comment(updated, obj)
            or found is None
        ):
            break
        parent, _ = found
        ancestor_key = ancestor[-1]
        if sum(prop.key == ancestor_key for prop in parent.properties) != 1:
            # Keep the empty effective object instead of exposing an older
            # shadowed duplicate section.
            break
        updated = _remove_property(updated, ancestor)
    return updated


def _setting(source: str, obj: ObjectRange, parts: list[str], value: Any) -> str:
    key = parts[0]
    if len(parts) == 1:
        encoded = _encode_json(value)
        prop = obj.property(key)
        if prop is not None:
            indent = _property_line_indent(source, prop)
            replacement = _format_value(encoded, indent, _preferred_newline(source))
            return source[: prop.value_start] + replacement + source[prop.value_end :]
        return _insert_property(source, obj, key, encoded)

    prop = obj.property(key)
    if prop is not None:
        start = _skip_ws_comments(source, prop.value_start)
        if start < len(source) and source[start] == "{":
            child = _parse_object(source, start)
            if child is None:
                raise JSONCEditError(f"malformed object at {key}")
            return _setting(source, child, parts[1:], value)

        # The standalone helper preserves its existing semantic policy: it
        # rejects scalar intermediates before reaching this text mutation.
        nested = _nested_object(parts[1:], value)
        encoded = _encode_json(nested)
        indent = _property_line_indent(source, prop)
        replacement = _format_value(encoded, indent, _preferred_newline(source))
        return source[: prop.value_start] + replacement + source[prop.value_end :]

    nested = _nested_object(parts[1:], value)
    return _insert_property(source, obj, key, _encode_json(nested))


def _nested_object(parts: list[str], value: Any) -> Any:
    result = value
    for key in reversed(parts):
        result = {key: result}
    return result


def _encode_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
        separators=(",", ": "),
    )


def _insert_property(source: str, obj: ObjectRange, key: str, value_json: str) -> str:
    newline = _preferred_newline(source)
    closing_indent = _indent_before_line(source, obj.close_brace)
    indent = _property_indent(source, obj)
    trailing_style = _has_trailing_comma(
        source,
        obj.properties[-1] if obj.properties else None,
        obj.close_brace,
    )
    prop = (
        f"{indent}{json.dumps(key, ensure_ascii=False)}: "
        f"{_format_value(value_json, indent, newline)}"
    )
    if trailing_style:
        prop += ","

    updated = source
    close = obj.close_brace
    if obj.properties and not trailing_style:
        last = obj.properties[-1]
        updated = updated[: last.value_end] + "," + updated[last.value_end :]
        if last.value_end <= close:
            close += 1

    line_start = _line_start(updated, close)
    close_own_line = all(ch in " \t" for ch in updated[line_start:close])
    if close_own_line:
        return updated[:line_start] + prop + newline + updated[line_start:]
    return updated[:close] + newline + prop + newline + closing_indent + updated[close:]


def _remove_property(source: str, parts: list[str]) -> str:
    found = _parent_and_property_index(source, parts)
    if found is None:
        return source
    parent, child_index = found
    child = parent.properties[child_index]
    line_start = _line_start(source, child.key_start)
    starts_own_line = all(ch in " \t" for ch in source[line_start : child.key_start])
    remove_start = line_start if starts_own_line else child.key_start

    comma = _following_comma(source, child.value_end, parent.close_brace)
    if comma is not None:
        remove_end = _attached_line_comment_end(source, comma + 1, starts_own_line)
        return source[:remove_start] + source[remove_end:]

    remove_end = _attached_line_comment_end(source, child.value_end, starts_own_line)
    if child_index == 0:
        return source[:remove_start] + source[remove_end:]

    previous = parent.properties[child_index - 1]
    separator = _following_comma(source, previous.value_end, child.key_start)
    if separator is None:
        raise JSONCEditError("could not find object property separator")
    return source[:separator] + source[separator + 1 : remove_start] + source[remove_end:]


def _parent_and_property_index(
    source: str,
    parts: list[str],
) -> tuple[ObjectRange, int] | None:
    obj = _root_object(source)
    if obj is None:
        return None
    for component in parts[:-1]:
        prop = obj.property(component)
        if prop is None:
            return None
        start = _skip_ws_comments(source, prop.value_start)
        if start >= len(source) or source[start] != "{":
            return None
        child = _parse_object(source, start)
        if child is None:
            return None
        obj = child
    for index in range(len(obj.properties) - 1, -1, -1):
        if obj.properties[index].key == parts[-1]:
            return obj, index
    return None


def _object_at_path(source: str, parts: list[str]) -> ObjectRange | None:
    obj = _root_object(source)
    if obj is None:
        return None
    for component in parts:
        prop = obj.property(component)
        if prop is None:
            return None
        start = _skip_ws_comments(source, prop.value_start)
        if start >= len(source) or source[start] != "{":
            return None
        obj = _parse_object(source, start)
        if obj is None:
            return None
    return obj


def _root_object(source: str) -> ObjectRange | None:
    index = _skip_ws_comments(source, 0)
    if index < len(source) and source[index] == "\ufeff":
        index = _skip_ws_comments(source, index + 1)
    if index >= len(source) or source[index] != "{":
        return None
    return _parse_object(source, index)


def _parse_object(source: str, open_brace: int) -> ObjectRange | None:
    close = _matching_container_end(source, open_brace)
    if close is None:
        return None
    props: list[PropertyRange] = []
    index = open_brace + 1
    while True:
        index = _skip_ws_comments(source, index)
        if index >= close:
            return ObjectRange(open_brace, close, tuple(props))
        if source[index] == ",":
            index += 1
            continue

        key_start = index
        parsed_key = _parse_json_string(source, key_start)
        if parsed_key is None:
            return None
        key, key_end = parsed_key
        index = _skip_ws_comments(source, key_end)
        if index >= close or source[index] != ":":
            return None
        value_start = _skip_ws_comments(source, index + 1)
        value_end = _skip_value(source, value_start)
        if value_end is None or value_start >= close:
            return None
        props.append(PropertyRange(key, key_start, value_start, value_end))
        index = value_end


def _matching_container_end(source: str, start: int) -> int | None:
    opening = source[start]
    if opening not in "{[":
        return None
    stack = ["}" if opening == "{" else "]"]
    index = start + 1
    while index < len(source):
        ch = source[index]
        if ch == '"':
            parsed = _parse_json_string(source, index)
            if parsed is None:
                return None
            index = parsed[1]
            continue
        if source.startswith("//", index):
            newline = _next_line_terminator(source, index + 2)
            index = len(source) if newline is None else newline
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            if end < 0:
                return None
            index = end + 2
            continue
        if ch == "{":
            stack.append("}")
        elif ch == "[":
            stack.append("]")
        elif ch == stack[-1]:
            stack.pop()
            if not stack:
                return index
        index += 1
    return None


def _skip_value(source: str, start: int) -> int | None:
    if start >= len(source):
        return None
    ch = source[start]
    if ch in "{[":
        end = _matching_container_end(source, start)
        return None if end is None else end + 1
    if ch == '"':
        parsed = _parse_json_string(source, start)
        return None if parsed is None else parsed[1]

    index = start
    while index < len(source):
        ch = source[index]
        if (
            ch in ",}]"
            or ch.isspace()
            or source.startswith("//", index)
            or source.startswith("/*", index)
        ):
            return index
        index += 1
    return index


def _parse_json_string(source: str, start: int) -> tuple[str, int] | None:
    if start >= len(source) or source[start] != '"':
        return None
    index = start + 1
    escaped = False
    while index < len(source):
        ch = source[index]
        if escaped:
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == '"':
            end = index + 1
            try:
                return json.loads(source[start:end]), end
            except json.JSONDecodeError:
                return None
        index += 1
    return None


def _skip_ws_comments(source: str, start: int) -> int:
    index = start
    while index < len(source):
        if source[index].isspace() or source[index] == "\ufeff":
            index += 1
            continue
        if source.startswith("//", index):
            newline = _next_line_terminator(source, index + 2)
            index = len(source) if newline is None else newline
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            if end < 0:
                return len(source)
            index = end + 2
            continue
        break
    return index


def _next_line_terminator(source: str, start: int) -> int | None:
    positions = [
        pos
        for pos in (source.find("\n", start), source.find("\r", start))
        if pos >= 0
    ]
    return min(positions) if positions else None


def _following_comma(source: str, start: int, limit: int) -> int | None:
    index = _skip_ws_comments(source, start)
    return index if index < limit and source[index] == "," else None


def _has_trailing_comma(
    source: str,
    prop: PropertyRange | None,
    close_brace: int,
) -> bool:
    return (
        prop is not None
        and _following_comma(source, prop.value_end, close_brace) is not None
    )


def _contains_comment(source: str, obj: ObjectRange) -> bool:
    body = source[obj.open_brace + 1 : obj.close_brace]
    return "//" in body or "/*" in body


def _attached_line_comment_end(
    source: str,
    start: int,
    consume_newline: bool,
) -> int:
    index = start
    while index < len(source) and source[index] in " \t":
        index += 1
    if source.startswith("//", index):
        newline = _next_line_terminator(source, index + 2)
        index = len(source) if newline is None else newline
    if consume_newline and index < len(source) and source[index] in "\r\n":
        if source.startswith("\r\n", index):
            return index + 2
        return index + 1
    return index


def _property_indent(source: str, obj: ObjectRange) -> str:
    closing = _indent_before_line(source, obj.close_brace)
    if obj.properties:
        first = obj.properties[0]
        start = _line_start(source, first.key_start)
        existing = source[start : first.key_start]
        if all(ch in " \t" for ch in existing) and len(existing) > len(closing):
            return existing
    return closing + "  "


def _property_line_indent(source: str, prop: PropertyRange) -> str:
    start = _line_start(source, prop.key_start)
    prefix = source[start : prop.key_start]
    return prefix if all(ch in " \t" for ch in prefix) else ""


def _indent_before_line(source: str, index: int) -> str:
    start = _line_start(source, index)
    cursor = start
    while cursor < len(source) and source[cursor] in " \t":
        cursor += 1
    return source[start:cursor]


def _line_start(source: str, index: int) -> int:
    cursor = index
    while cursor > 0 and source[cursor - 1] not in "\r\n":
        cursor -= 1
    return cursor


def _preferred_newline(source: str) -> str:
    if "\r\n" in source:
        return "\r\n"
    if "\r" in source:
        return "\r"
    return "\n"


def _format_value(value_json: str, property_indent: str, newline: str) -> str:
    normalized = value_json.replace("\n", newline) if newline != "\n" else value_json
    lines = normalized.split(newline)
    return lines[0] + "".join(
        newline + property_indent + line
        for line in lines[1:]
    )

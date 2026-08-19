#!/usr/bin/env python3
"""Generate the checked-in cmux.json key reference from the JSON schema.

The schema is the authority for the configuration contract.  This script keeps
the prose in ``docs/configuration.md`` useful while replacing a marked,
generated section on every run.  It deliberately understands the small set of
JSON-Schema constructs used by cmux instead of relying on a third-party schema
library, so the CI check works on a clean Python installation.
"""

from __future__ import annotations

import argparse
import copy
import json
import pathlib
import sys
from dataclasses import dataclass
from typing import Any, Iterable


BEGIN_MARKER = "<!-- BEGIN GENERATED CONFIGURATION REFERENCE. Do not edit. -->"
END_MARKER = "<!-- END GENERATED CONFIGURATION REFERENCE. -->"
DEFAULT_SCHEMA = pathlib.Path("web/data/cmux.schema.json")
DEFAULT_OUTPUT = pathlib.Path("docs/configuration.md")
MISSING = object()


@dataclass(frozen=True)
class KeyEntry:
    path: str
    type_text: str
    default_text: str
    constraints: str
    description: str


class SchemaReader:
    """Resolve local refs and flatten a schema into deterministic key rows."""

    def __init__(self, document: dict[str, Any]) -> None:
        self.document = document
        self.definitions = document.get("$defs", {})

    def resolve(self, schema: Any, stack: tuple[str, ...] = ()) -> dict[str, Any]:
        if not isinstance(schema, dict):
            return {}
        ref = schema.get("$ref")
        if not isinstance(ref, str) or not ref.startswith("#/"):
            return copy.deepcopy(schema)
        if ref in stack:
            # Recursive schemas (for example a tree-shaped action) still need
            # an entry, but recursively expanding them would never terminate.
            return {"description": f"Reference to `{ref}` (recursive)"}
        target: Any = self.document
        for component in ref[2:].split("/"):
            component = component.replace("~1", "/").replace("~0", "~")
            if not isinstance(target, dict) or component not in target:
                return {"description": f"Unresolved schema reference `{ref}`"}
            target = target[component]
        resolved = self.resolve(target, stack + (ref,))
        # A property can override metadata supplied by its referenced
        # definition (notably default and description), so merge the local
        # object after resolving the target.
        merged = copy.deepcopy(resolved)
        merged.update({key: copy.deepcopy(value) for key, value in schema.items() if key != "$ref"})
        return merged

    def entries(self) -> list[KeyEntry]:
        result: list[KeyEntry] = []
        properties = self.document.get("properties", {})
        if isinstance(properties, dict):
            for name, schema in properties.items():
                self._walk(str(name), schema, result, set())
        # A composition branch can be reached both while walking the operator
        # itself and while walking its parent.  Those traversals describe the
        # same JSON key, so keep the first deterministic row rather than
        # emitting duplicate documentation (for example `items[].*`).
        unique: list[KeyEntry] = []
        seen_paths: set[str] = set()
        for entry in result:
            if entry.path in seen_paths:
                continue
            seen_paths.add(entry.path)
            unique.append(entry)
        return unique

    def _walk(
        self,
        path: str,
        schema: Any,
        result: list[KeyEntry],
        seen: set[tuple[str, str]],
    ) -> None:
        resolved = self.resolve(schema)
        signature = (path, json.dumps(resolved, sort_keys=True, default=str))
        if signature in seen:
            return
        seen.add(signature)

        # Conditional and composition branches may redeclare a discriminator
        # with only a `const`. The canonical declaration was emitted first by
        # `_walk_children`; do not make the metadata-only redeclaration replace
        # (or invalidate) that documented row.
        if not any(entry.path == path for entry in result):
            result.append(self._entry(path, resolved))

        self._walk_children(path, resolved, result, seen)

    def _walk_children(
        self,
        path: str,
        schema: dict[str, Any],
        result: list[KeyEntry],
        seen: set[tuple[str, str]],
    ) -> None:
        # Walk the canonical object shape before composition and conditional
        # branches. A discriminator often repeats a property with only a
        # `const`; visiting that branch first would make path deduplication
        # discard the primary declaration's type, default, and description.
        properties = schema.get("properties")
        if isinstance(properties, dict):
            for name, child in properties.items():
                self._walk(f"{path}.{name}", child, result, seen)

        additional = schema.get("additionalProperties")
        if additional is True:
            result.append(
                self._entry(
                    f"{path}.*",
                    {
                        "type": "any",
                        "description": "Dynamic configuration entry. Any JSON value is accepted.",
                        "_dynamic": True,
                    },
                )
            )
        elif isinstance(additional, dict):
            dynamic = self.resolve(additional)
            dynamic["_dynamic"] = True
            property_names = schema.get("propertyNames")
            if isinstance(property_names, dict):
                dynamic["_propertyNames"] = self.resolve(property_names)
            self._walk(f"{path}.*", dynamic, result, seen)

        items = schema.get("items")
        if isinstance(items, dict):
            item_schema = self.resolve(items)
            # `[]` makes array members unambiguous in the generated reference,
            # while retaining the parent array row above.
            self._walk(f"{path}[]", item_schema, result, seen)

        # Composition branches can carry additional properties (for example
        # the conditional fields on an array member). Walk every composition
        # operator rather than only `oneOf`; otherwise the generated reference
        # silently omits keys that editors still validate.
        for operator in ("oneOf", "anyOf", "allOf"):
            branches = schema.get(operator)
            if isinstance(branches, list):
                for branch in branches:
                    self._walk_children(path, self.resolve(branch), result, seen)

        # Conditional schemas can introduce properties that do not appear in
        # the unconditional object shape. Walk every branch so a key accepted
        # only by `then` or `else` cannot disappear from the generated
        # reference. Walking `if` as well documents discriminator properties
        # when the parent does not declare them separately.
        for operator in ("if", "then", "else"):
            branch = schema.get(operator)
            if isinstance(branch, dict):
                self._walk_children(path, self.resolve(branch), result, seen)

        # Draft 2019-09+ dependent schemas are conditional object branches too.
        # Each value applies at the same JSON path as its parent.
        dependent_schemas = schema.get("dependentSchemas")
        if isinstance(dependent_schemas, dict):
            for branch in dependent_schemas.values():
                if isinstance(branch, dict):
                    self._walk_children(path, self.resolve(branch), result, seen)

    def _entry(self, path: str, schema: dict[str, Any]) -> KeyEntry:
        return KeyEntry(
            path=path,
            type_text=format_type(schema, self),
            default_text=format_default(schema.get("default", MISSING), schema, self),
            constraints=format_constraints(schema),
            description=format_description(schema, self, path=path),
        )


def format_type(schema: dict[str, Any], reader: SchemaReader) -> str:
    branches = schema.get("oneOf") or schema.get("anyOf")
    if isinstance(branches, list) and branches:
        return join_types(format_type(reader.resolve(branch), reader) for branch in branches)

    all_of = schema.get("allOf")
    if isinstance(all_of, list) and all_of:
        # `allOf` is an intersection, but for documentation the useful type is
        # the concrete type supplied by any constituent. JSON-Schema helper
        # definitions commonly put a `$ref` and a pattern-bearing `anyOf`
        # side-by-side here.
        concrete = join_types(
            format_type(reader.resolve(part), reader) for part in all_of
        )
        if concrete != "any":
            return concrete

    raw_type = schema.get("type")
    if isinstance(raw_type, list):
        return " | ".join(str(value) for value in raw_type)
    if raw_type == "array":
        items = schema.get("items")
        if isinstance(items, dict):
            return f"array<{format_type(reader.resolve(items), reader)}>"
        prefix_items = schema.get("prefixItems")
        if isinstance(prefix_items, list) and prefix_items:
            return f"array<{join_types(format_type(reader.resolve(item), reader) for item in prefix_items)}>"
        return "array<any>"
    if raw_type == "object":
        if schema.get("_dynamic"):
            additional = schema.get("additionalProperties")
            if isinstance(additional, dict):
                return f"map<string, {format_type(reader.resolve(additional), reader)}>"
            return "map<string, any>"
        return "object"
    if raw_type:
        return str(raw_type)
    if "const" in schema:
        return json_value_type(schema["const"])
    inferred = infer_type_from_schema(schema)
    if inferred is not None:
        return inferred
    return "any"


def join_types(values: Iterable[str]) -> str:
    flattened: list[str] = []
    for value in values:
        for component in value.split(" | "):
            if component not in flattened:
                flattened.append(component)
    # `any` is an implementation/documentation fallback. When a union also
    # has concrete branches, retaining it makes the reference say things like
    # `string | any`, which is less useful than the actual accepted shapes.
    if len(flattened) > 1 and "any" in flattened:
        flattened.remove("any")
    return " | ".join(flattened) or "any"


def json_value_type(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int) and not isinstance(value, bool):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return "any"


def infer_type_from_schema(schema: dict[str, Any]) -> str | None:
    """Infer the common primitive type for constraint-only schema branches."""
    if any(key in schema for key in ("pattern", "minLength", "maxLength", "format")):
        return "string"
    if any(key in schema for key in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf")):
        return "number"
    enum = schema.get("enum")
    if isinstance(enum, list) and enum:
        return join_types(json_value_type(value) for value in enum)
    if isinstance(schema.get("properties"), dict) or "required" in schema:
        return "object"
    return None


def format_default(value: Any, schema: dict[str, Any], reader: SchemaReader) -> str:
    if value is MISSING:
        branches = schema.get("oneOf") or schema.get("anyOf") or schema.get("allOf")
        if isinstance(branches, list):
            for branch in branches:
                resolved = reader.resolve(branch)
                if "default" in resolved:
                    return format_default(resolved["default"], resolved, reader)
        return "—"
    return f"`{json.dumps(value, ensure_ascii=False, sort_keys=True)}`"


def format_description(
    schema: dict[str, Any],
    reader: SchemaReader,
    path: str | None = None,
) -> str:
    direct = schema.get("description")
    if isinstance(direct, str) and direct.strip():
        return direct.strip()
    branches = schema.get("oneOf") or schema.get("anyOf") or schema.get("allOf")
    if isinstance(branches, list):
        descriptions: list[str] = []
        for branch in branches:
            # A branch without its own prose must not synthesize a generic
            # description here. The containing row owns the final path-aware
            # fallback after every branch has had a chance to contribute real
            # schema documentation.
            description = format_description(reader.resolve(branch), reader)
            if description and description not in descriptions:
                descriptions.append(description)
        # A referenced union can appear inside another union (for example a
        # nullable shortcut binding). Drop descriptions that are wholly
        # repeated inside a longer description to keep the generated row
        # readable without losing any distinct branch explanation.
        descriptions = [
            description
            for description in descriptions
            if not any(
                other != description and description in other
                for other in descriptions
            )
        ]
        if descriptions:
            return " ".join(descriptions)

    # Structural rows (`[]` array members and `.*` dynamic map entries) are
    # useful in a complete reference even when the parent schema supplies the
    # prose. Explicit properties, however, must carry real schema prose: a
    # generic sentence would make CI green while still leaving the reference
    # undocumented.
    if path is not None:
        if path.endswith("[]"):
            return "One array member accepted by this setting."
        if path.endswith(".*"):
            return "One dynamic entry accepted under this setting."
        raise ValueError(f"schema key {path!r} is missing a description")
    return ""


def format_constraints(schema: dict[str, Any]) -> str:
    parts: list[str] = []
    enum = schema.get("enum")
    if isinstance(enum, list):
        parts.append("enum: " + ", ".join(f"`{json.dumps(item, ensure_ascii=False)}`" for item in enum))
    if "const" in schema:
        parts.append(f"const: `{json.dumps(schema['const'], ensure_ascii=False)}`")
    for key, label in (
        ("minimum", "min"),
        ("maximum", "max"),
        ("multipleOf", "step"),
        ("minLength", "min length"),
        ("maxLength", "max length"),
        ("minItems", "min items"),
        ("maxItems", "max items"),
        ("pattern", "pattern"),
        ("format", "format"),
        ("exclusiveMinimum", "exclusive min"),
        ("exclusiveMaximum", "exclusive max"),
    ):
        if key in schema:
            parts.append(f"{label}: `{json.dumps(schema[key], ensure_ascii=False)}`")
    property_names = schema.get("_propertyNames")
    if isinstance(property_names, dict) and isinstance(property_names.get("enum"), list):
        values = ", ".join(f"`{value}`" for value in property_names["enum"])
        parts.append(f"key enum: {values}")
    if schema.get("_dynamic"):
        parts.append("dynamic key")
    return "; ".join(parts) or "—"


def markdown_escape(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ").strip()


def render_reference(schema_path: pathlib.Path, document: dict[str, Any]) -> str:
    reader = SchemaReader(document)
    entries = reader.entries()
    lines = [
        BEGIN_MARKER,
        "",
        "## Generated schema key reference",
        "",
        f"Source: [`{schema_path.as_posix()}`](../{schema_path.as_posix()})",
        "",
        "This section is generated by `scripts/generate-config-docs.py`. Every explicit schema property is listed; `.*` and `[]` rows describe dynamic map keys and array members.",
        "",
        "| Key | Type | Default | Constraints | Description |",
        "| --- | --- | --- | --- | --- |",
    ]
    for entry in entries:
        lines.append(
            "| "
            + " | ".join(
                markdown_escape(value)
                for value in (
                    f"`{entry.path}`",
                    entry.type_text,
                    entry.default_text,
                    entry.constraints,
                    entry.description or "—",
                )
            )
            + " |"
        )
    lines.extend(["", END_MARKER, ""])
    return "\n".join(lines)


def update_document(existing: str, generated: str) -> str:
    begin = existing.find(BEGIN_MARKER)
    end = existing.find(END_MARKER)
    if begin >= 0 and end >= 0 and end >= begin:
        end += len(END_MARKER)
        # Keep any hand-written material that follows the generated section.
        # This matters for callers embedding the reference in a larger
        # document (and makes the replacement operation truly marker-scoped).
        return (
            existing[:begin].rstrip()
            + "\n\n"
            + generated.rstrip()
            + "\n"
            + existing[end:].lstrip("\n")
        )
    return existing.rstrip() + "\n\n" + generated


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="write the generated reference")
    parser.add_argument("--check", action="store_true", help="fail when the checked-in reference is stale")
    parser.add_argument("--schema", type=pathlib.Path, default=DEFAULT_SCHEMA)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    if args.write == args.check:
        parser.error("choose exactly one of --write or --check")
    return args


def main() -> int:
    args = parse_args()
    try:
        document = json.loads(args.schema.read_text(encoding="utf-8"))
        existing = args.output.read_text(encoding="utf-8") if args.output.exists() else ""
        generated = render_reference(args.schema, document)
        expected = update_document(existing, generated)
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
        print(f"generate-config-docs: {error}", file=sys.stderr)
        return 1

    if args.write:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(expected, encoding="utf-8")
        return 0

    if not args.output.exists() or args.output.read_text(encoding="utf-8") != expected:
        print(
            f"{args.output} is stale; run python3 scripts/generate-config-docs.py --write",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Behavior tests for the schema-to-Markdown configuration reference."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "generate-config-docs.py"


def run_generator(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def test_generator_resolves_refs_and_documents_dynamic_shapes() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        schema = root / "schema.json"
        output = root / "configuration.md"
        schema.write_text(
            json.dumps(
                {
                    "$defs": {
                        "mode": {
                            "type": "string",
                            "enum": ["one", "two"],
                            "description": "Mode description.",
                        },
                        "labelName": {"enum": ["red", "blue"]},
                    },
                    "type": "object",
                    "properties": {
                        "terminal": {
                            "type": "object",
                            "description": "Terminal configuration.",
                            "properties": {
                                "mode": {"$ref": "#/$defs/mode", "default": "one"},
                                "items": {
                                    "type": "array",
                                    "description": "Configured items.",
                                    "items": {
                                        "type": "object",
                                        "description": "One configured item.",
                                        "properties": {
                                            "name": {
                                                "type": "string",
                                                "description": "Item name.",
                                            }
                                        },
                                    },
                                },
                                "labels": {
                                    "type": "object",
                                    "description": "Configured labels.",
                                    "propertyNames": {"$ref": "#/$defs/labelName"},
                                    "additionalProperties": {"type": "string"},
                                },
                            },
                            "additionalProperties": False,
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        result = run_generator("--write", "--schema", str(schema), "--output", str(output))
        assert result.returncode == 0, result.stderr
        text = output.read_text(encoding="utf-8")
        assert "`terminal.mode`" in text
        assert 'enum: `"one"`, `"two"`' in text
        assert "`terminal.items[]`" in text
        assert "`terminal.items[].name`" in text
        assert "`terminal.labels.*`" in text
        assert "key enum: `red`, `blue`" in text


def test_check_fails_closed_when_generated_section_is_stale() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        schema = root / "schema.json"
        output = root / "configuration.md"
        schema.write_text(
            '{"type":"object","properties":{"enabled":{"type":"boolean","description":"Whether enabled."}}}',
            encoding="utf-8",
        )
        output.write_text("# stale\n", encoding="utf-8")
        result = run_generator("--check", "--schema", str(schema), "--output", str(output))
        assert result.returncode != 0
        assert "stale" in result.stderr


def test_generator_walks_any_of_and_all_of_child_properties() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        schema = root / "schema.json"
        output = root / "configuration.md"
        schema.write_text(
            json.dumps(
                {
                    "type": "object",
                    "properties": {
                        "surface": {
                            "type": "object",
                            "description": "Surface configuration.",
                            "allOf": [
                                {
                                    "properties": {
                                        "common": {
                                            "type": "boolean",
                                            "description": "Common flag.",
                                        }
                                    }
                                },
                                {
                                    "anyOf": [
                                        {
                                            "properties": {
                                                "login": {
                                                    "type": "boolean",
                                                    "description": "Login flag.",
                                                }
                                            }
                                        },
                                        {
                                            "properties": {
                                                "command": {
                                                    "type": "string",
                                                    "description": "Startup command.",
                                                }
                                            }
                                        },
                                    ]
                                },
                            ],
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        result = run_generator("--write", "--schema", str(schema), "--output", str(output))
        assert result.returncode == 0, result.stderr
        text = output.read_text(encoding="utf-8")
        assert "`surface.common`" in text
        assert "`surface.login`" in text
        assert "`surface.command`" in text
        assert text.count("`surface.common`") == 1


def test_generator_walks_conditional_only_properties() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        schema = root / "schema.json"
        output = root / "configuration.md"
        schema.write_text(
            json.dumps(
                {
                    "type": "object",
                    "properties": {
                        "terminal": {
                            "type": "object",
                            "description": "Terminal configuration.",
                            "properties": {
                                "mode": {
                                    "type": "string",
                                    "default": "inherit",
                                    "description": "Canonical mode description.",
                                }
                            },
                            "if": {
                                "properties": {
                                    "mode": {"const": "fixed"},
                                }
                            },
                            "then": {
                                "properties": {
                                    "fixedPath": {
                                        "type": "string",
                                        "description": "Fixed path.",
                                    },
                                }
                            },
                            "else": {
                                "properties": {
                                    "fallbackPath": {
                                        "type": "string",
                                        "description": "Fallback path.",
                                    },
                                }
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        result = run_generator("--write", "--schema", str(schema), "--output", str(output))
        assert result.returncode == 0, result.stderr
        text = output.read_text(encoding="utf-8")
        assert "`terminal.mode`" in text
        assert text.count("`terminal.mode`") == 1
        assert "Canonical mode description." in text
        assert '`"inherit"`' in text
        assert "`terminal.fixedPath`" in text
        assert "`terminal.fallbackPath`" in text


def test_generator_preserves_content_after_generated_section() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        schema = root / "schema.json"
        output = root / "configuration.md"
        schema.write_text(
            json.dumps(
                {
                    "type": "object",
                    "properties": {
                        "enabled": {
                            "type": "boolean",
                            "default": True,
                            "description": "Whether enabled.",
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        output.write_text(
            "# Before\n\n"
            + "<!-- BEGIN GENERATED CONFIGURATION REFERENCE. Do not edit. -->\n"
            + "old\n"
            + "<!-- END GENERATED CONFIGURATION REFERENCE. -->\n\n"
            + "## After\n\nKeep this prose.\n",
            encoding="utf-8",
        )
        result = run_generator("--write", "--schema", str(schema), "--output", str(output))
        assert result.returncode == 0, result.stderr
        text = output.read_text(encoding="utf-8")
        assert text.startswith("# Before\n\n")
        assert "`enabled`" in text
        assert text.endswith("## After\n\nKeep this prose.\n")


def test_generator_rejects_an_undocumented_explicit_key() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        schema = root / "schema.json"
        output = root / "configuration.md"
        schema.write_text(
            json.dumps(
                {
                    "type": "object",
                    "properties": {
                        "items": {
                            "type": "array",
                            "description": "Configured items.",
                            "items": {
                                "type": "object",
                                "properties": {"name": {"type": "string"}},
                                "additionalProperties": {"type": "number"},
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        result = run_generator("--write", "--schema", str(schema), "--output", str(output))
        assert result.returncode != 0
        assert "items[].name" in result.stderr
        assert "missing a description" in result.stderr


def test_generator_documents_structural_rows_without_placeholder_properties() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        schema = root / "schema.json"
        output = root / "configuration.md"
        schema.write_text(
            json.dumps(
                {
                    "type": "object",
                    "properties": {
                        "items": {
                            "type": "array",
                            "description": "Configured items.",
                            "items": {
                                "type": "object",
                                "description": "One configured item.",
                                "properties": {
                                    "name": {
                                        "type": "string",
                                        "description": "Item name.",
                                    }
                                },
                                "additionalProperties": {
                                    "type": "number",
                                    "description": "Numeric custom metadata.",
                                },
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        result = run_generator("--write", "--schema", str(schema), "--output", str(output))
        assert result.returncode == 0, result.stderr
        text = output.read_text(encoding="utf-8")
        assert "Item name." in text
        assert "One configured item." in text
        assert "Numeric custom metadata." in text

        reference_rows = [line for line in text.splitlines() if line.startswith("| `")]
        assert reference_rows
        assert all(not line.endswith("| — |") for line in reference_rows)


if __name__ == "__main__":
    test_generator_resolves_refs_and_documents_dynamic_shapes()
    test_check_fails_closed_when_generated_section_is_stale()
    test_generator_walks_any_of_and_all_of_child_properties()
    test_generator_walks_conditional_only_properties()
    test_generator_preserves_content_after_generated_section()
    test_generator_rejects_an_undocumented_explicit_key()
    test_generator_documents_structural_rows_without_placeholder_properties()

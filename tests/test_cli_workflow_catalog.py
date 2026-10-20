#!/usr/bin/env python3
"""Contract checks for no-socket workflow/template discovery."""

from __future__ import annotations

import glob
import json
import os
import re
import plistlib
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path


RECIPE_PATH = (
    Path(__file__).resolve().parent.parent
    / "skills"
    / "cmux-customization"
    / "references"
    / "examples.md"
)

EXPECTED_LAYOUT_COMMANDS = {
    "cmux layout list --json",
    "cmux layout get <name>",
    "cmux layout open <name> --cwd <project>",
    'cmux layout save <name> --description "<what this creates>"',
    "cmux layout delete <name>",
}

REQUIRED_EXAMPLE_FIELDS = {
    "id",
    "title",
    "summary",
    "fit",
    "creates",
    "config_files",
    "primitives",
    "requires",
    "instantiate",
    "adapt",
    "source",
}


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates = glob.glob(
        os.path.expanduser(
            "~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux"
        )
    )
    candidates = [
        path for path in candidates if os.path.exists(path) and os.access(path, os.X_OK)
    ]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def run_cli(cli_path: str, args: list[str], language: str = "en") -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["AppleLanguages"] = f"({language})"
    for key in [
        "CMUX_SOCKET_PASSWORD",
        "CMUX_SOCKET",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
    ]:
        env.pop(key, None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

    with tempfile.TemporaryDirectory(prefix="cmux-workflow-catalog-") as tmpdir:
        env["CMUX_SOCKET_PATH"] = os.path.join(
            tmpdir, f"missing-{uuid.uuid4().hex}.sock"
        )
        return subprocess.run(
            [cli_path, *args],
            text=True,
            capture_output=True,
            check=False,
            timeout=60.0,
            env=env,
        )


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def recipe_example_ids() -> set[str]:
    text = RECIPE_PATH.read_text(encoding="utf-8")
    headings = re.findall(r"^## (.+)$", text, flags=re.MULTILINE)
    headings = [heading for heading in headings if heading != "Validation checklist"]
    return {
        re.sub(r"[^a-z0-9]+", "-", heading.lower()).strip("-")
        for heading in headings
    }


def load_json(proc: subprocess.CompletedProcess[str], label: str) -> dict:
    require(proc.returncode == 0, f"{label}: exit {proc.returncode}: {proc.stderr!r}")
    require(not proc.stderr.strip(), f"{label}: unexpected stderr: {proc.stderr!r}")
    try:
        value = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{label}: invalid JSON: {exc}: {proc.stdout!r}") from exc
    require(isinstance(value, dict), f"{label}: expected JSON object")
    return value


def paired(left: list, right: list):
    require(len(left) == len(right), "Localized list length changed")
    return zip(left, right)


def check_localized_field(original, localized, label: str) -> None:
    if isinstance(original, list):
        for original_item, localized_item in paired(original, localized):
            if original_item in {"codex", "claude"}:
                require(original_item == localized_item, f"{label}: executable name changed")
            else:
                require(original_item != localized_item, f"{label}: untranslated item")
    else:
        require(original != localized, f"{label}: untranslated")


def check_localized_catalog(cli_path: str) -> None:
    """Exercise shipped translations through the executable's app-bundle lookup."""
    with tempfile.TemporaryDirectory(prefix="cmux-workflow-localization-") as tmpdir:
        contents = Path(tmpdir) / "WorkflowTest.app" / "Contents"
        resources = contents / "Resources"
        executable = resources / "bin" / "cmux"
        executable.parent.mkdir(parents=True)
        shutil.copy2(cli_path, executable)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.cmux.workflow-localization-test",
            "CFBundleDevelopmentRegion": "en",
            "CFBundlePackageType": "APPL",
        }))
        subprocess.run([
            "xcrun", "xcstringstool", "compile",
            str(RECIPE_PATH.parents[3] / "Resources" / "Localizable.xcstrings"),
            "--output-directory", str(resources),
        ], check=True, capture_output=True, text=True)
        english = load_json(run_cli(str(executable), ["docs", "workflows", "--json"]), "English catalog")
        # Invariant command syntax embedded in otherwise translatable guidance.
        literals = re.compile(
            r"cmux layout save <name> --description \"<what this creates>\"|"
            r"cmux reload-config|gh pr status|ssh devbox|"
            r"(?:~/\.config/cmux/|\.cmux/)?(?:cmux|dock)\.json|"
            r"actions/ui/commands|actions/ui|<name>"
        )
        for language in ["de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja"]:
            localized = load_json(
                run_cli(str(executable), ["docs", "workflows", "--json"], language),
                f"{language} catalog",
            )
            require(localized.keys() == english.keys(), f"{language}: JSON keys changed")
            require(localized["commands"] == english["commands"], f"{language}: commands changed")
            require(localized["summary"] != english["summary"], f"{language}: untranslated summary")
            for base, translated in paired(english["examples"], localized["examples"]):
                require(base.keys() == translated.keys(), f"{language}: example keys changed")
                for field in ["id", "config_files", "source"]:
                    require(base[field] == translated[field], f"{language}: invariant {field} changed")
                for field in ["title", "summary", "fit", "creates", "requires", "instantiate", "adapt"]:
                    check_localized_field(base[field], translated[field], f"{language}: {base['id']}.{field}")
                    require(literals.findall(str(base[field])) == literals.findall(str(translated[field])),
                            f"{language}: command/path syntax changed in {base['id']}.{field}")
                for primitive in base["primitives"]:
                    if "." in primitive or primitive.startswith("cmux "):
                        require(primitive in translated["primitives"], f"{language}: primitive syntax changed")
            for base, translated in paired(english["saved_layouts"]["steps"], localized["saved_layouts"]["steps"]):
                require(base["command"] == translated["command"], f"{language}: layout command changed")
                require(base["label"] != translated["label"], f"{language}: layout label untranslated")
            require(english["saved_layouts"]["description"] != localized["saved_layouts"]["description"],
                    f"{language}: saved layout description untranslated")
            for base, translated in paired(english["saved_layouts"]["native_surfaces"], localized["saved_layouts"]["native_surfaces"]):
                require(base != translated, f"{language}: native entry point untranslated")
                require(literals.findall(base) == literals.findall(translated), f"{language}: native placeholder changed")
            for base, translated in paired(english["adapt_and_save"], localized["adapt_and_save"]):
                require(base != translated, f"{language}: adaptation guidance untranslated")
                require(literals.findall(base) == literals.findall(translated), f"{language}: guidance syntax changed")
        japanese = run_cli(str(executable), ["docs", "workflows"], "ja")
        require(japanese.returncode == 0, "Japanese plain output failed")
        require("用途:" in japanese.stdout and "必要なもの:" in japanese.stdout,
                "Japanese labels fell back to English")
        layout_help = run_cli(str(executable), ["layout", "--help"], "ja")
        require(layout_help.returncode == 0, "Japanese layout help failed")
        require("ワークフローのひな形を探す：" in layout_help.stdout, "Layout-help heading fell back to English")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()

        plain = run_cli(cli_path, ["docs", "workflows"])
        require(plain.returncode == 0, f"plain workflow docs failed: {plain.stderr!r}")
        require(not plain.stderr.strip(), f"plain workflow docs wrote stderr: {plain.stderr!r}")
        for needle in [
            "Saved layouts:",
            "Shipped workflow examples:",
            "Adapt and save:",
            "cmux layout list --json",
            "cmux layout save <name>",
        ]:
            require(needle in plain.stdout, f"plain workflow docs missing {needle!r}")

        canonical = load_json(
            run_cli(cli_path, ["docs", "workflows", "--json"]),
            "cmux docs workflows --json",
        )
        require(canonical.get("topic") == "workflows", "workflow topic must be canonical")
        require(canonical.get("catalog_version") == 1, "workflow catalog version must be 1")

        examples = canonical.get("examples")
        require(isinstance(examples, list), "examples must be a list")
        ids = {example.get("id") for example in examples if isinstance(example, dict)}
        recipe_ids = recipe_example_ids()
        require(
            ids == recipe_ids,
            f"catalog ids must match shipped recipe headings: catalog={sorted(str(x) for x in ids)} recipes={sorted(recipe_ids)}",
        )
        require(len(examples) == len(ids), "workflow example ids must be unique")
        for example in examples:
            require(isinstance(example, dict), "each workflow example must be an object")
            missing = REQUIRED_EXAMPLE_FIELDS - set(example)
            require(not missing, f"{example.get('id')}: missing fields {sorted(missing)}")
            for key in ["title", "summary", "source"]:
                require(
                    isinstance(example[key], str) and example[key].strip(),
                    f"{example['id']}: {key} must be non-empty",
                )
            for key in [
                "fit",
                "creates",
                "config_files",
                "primitives",
                "instantiate",
                "adapt",
            ]:
                require(
                    isinstance(example[key], list) and example[key],
                    f"{example['id']}: {key} must be a non-empty list",
                )
            require(
                isinstance(example["requires"], list),
                f"{example['id']}: requires must be a list",
            )
            require(
                example["source"]
                == (
                    "https://github.com/manaflow-ai/cmux/blob/main/"
                    "skills/cmux-customization/references/examples.md#"
                    f"{example['id']}"
                ),
                f"{example['id']}: source must point at its matching shipped recipe",
            )

        saved_layouts = canonical.get("saved_layouts")
        require(isinstance(saved_layouts, dict), "saved_layouts must be an object")
        steps = saved_layouts.get("steps")
        require(isinstance(steps, list), "saved_layouts.steps must be a list")
        layout_commands = {
            step.get("command") for step in steps if isinstance(step, dict)
        }
        require(
            layout_commands == EXPECTED_LAYOUT_COMMANDS,
            f"unexpected saved-layout commands: {sorted(layout_commands)}",
        )
        native_surfaces = saved_layouts.get("native_surfaces")
        require(
            isinstance(native_surfaces, list) and len(native_surfaces) >= 3,
            "saved layouts must expose their native discovery entry points",
        )

        adapt_and_save = canonical.get("adapt_and_save")
        require(
            isinstance(adapt_and_save, list) and adapt_and_save,
            "catalog must explain how to adapt and save a result",
        )

        alias = load_json(
            run_cli(cli_path, ["docs", "templates", "--json"]),
            "cmux docs templates --json",
        )
        require(alias == canonical, "templates alias must return the canonical catalog")

        index = load_json(run_cli(cli_path, ["docs", "--json"]), "cmux docs --json")
        topics = index.get("topics")
        require(isinstance(topics, list), "docs index topics must be a list")
        workflow_topics = [
            topic
            for topic in topics
            if isinstance(topic, dict) and topic.get("topic") == "workflows"
        ]
        require(
            workflow_topics == [canonical],
            "docs index and workflow topic must use the same catalog payload",
        )
        check_localized_catalog(cli_path)
    except (OSError, RuntimeError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as exc:
        print(f"FAIL: {exc}")
        return 1

    print("PASS: workflow catalog is discoverable without a socket and exposes canonical human/agent metadata")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

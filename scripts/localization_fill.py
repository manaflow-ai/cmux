#!/usr/bin/env python3
"""localization-fill: the bot that fills the non-source locales on main.

Pull requests write the source locales only: English and Japanese (web/messages/en.json, ja.json, and the en and ja
entries of every macOS string catalog). A missing entry in any other locale falls back to English at runtime
(web/i18n/messages.ts deep-merges English under every locale; a missing XCStrings entry shows the Swift
defaultValue). .github/workflows/localization-fill.yml runs this on main:

    localization_fill.py gaps   --repo-dir DIR --out packet.json --prompt-out prompt.txt
        what the bot locales lack: missing web keys and macOS entries, and translations left behind after their
        English source changed since the last fill (state: scripts/localization-fill-state.json).
    localization_fill.py apply  --repo-dir DIR --packet packet.json --answer translator.json
        validates each translation (placeholders, ICU arguments, rich-text tags; macOS rows through
        localization_catalog.merge_text) and writes the ones that pass; the rest stay for the next run.
    localization_fill.py open   --repo-dir DIR --push-url URL --repo OWNER/NAME --base main
        commits, force-pushes localization-fill/main and opens (or refreshes) its pull request.

Keys that a locale already lacked when this bot started (scripts/localization-fill-state.json "englishOnly", per
space-separated locales, "*" for all) stay English-only, as they were by design (pricing, blog posts, docs pages authored only in
English). Delete a prefix there to have the bot translate that subtree.
"""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import re
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
_SPEC = importlib.util.spec_from_file_location("cmux_localization_catalog", SCRIPT_DIR / "localization_catalog.py")
if _SPEC is None or _SPEC.loader is None:
    raise RuntimeError("unable to load scripts/localization_catalog.py")
CATALOG = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = CATALOG
_SPEC.loader.exec_module(CATALOG)

STATE = "scripts/localization-fill-state.json"
WEB_DIR = "web/messages"
WEB_SOURCE_LOCALES = ("en", "ja")
WEB_LOCALES = re.compile(r"export\s+const\s+locales\s*=\s*\[(?P<body>[\s\S]*?)\]\s*as\s+const")
QUOTED = re.compile(r'"([^"\\]+)"')
ICU_ARGUMENT = re.compile(r"\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*[,}]")
TAG = re.compile(r"</?([A-Za-z][A-Za-z0-9_-]*)\s*/?>")
BRANCH = "localization-fill/main"
BOT = ("cmux localization-fill", "41898282+github-actions[bot]@users.noreply.github.com")
LIMIT = 150
PROMPT_BUDGET = 90_000


# ---------------------------------------------------------------- shared helpers

def git(repo: Path, *argv: str, check: bool = True) -> str:
    out = subprocess.run(["git", *argv], cwd=repo, capture_output=True, text=True)
    if check and out.returncode:
        raise RuntimeError(f"git {' '.join(argv)}: {out.stderr.strip()[-400:]}")
    return out.stdout


def show(repo: Path, rev: str, path: str) -> str | None:
    if not rev:
        return None
    out = subprocess.run(["git", "show", f"{rev}:{path}"], cwd=repo, capture_output=True, text=True)
    return out.stdout if out.returncode == 0 else None


def load_state(repo: Path) -> dict:
    return json.loads((repo / STATE).read_text(encoding="utf-8"))


def web_locales(repo: Path) -> tuple[str, ...]:
    match = WEB_LOCALES.search((repo / "web/i18n/routing.ts").read_text(encoding="utf-8"))
    if not match:
        raise ValueError("cannot parse web/i18n/routing.ts locale list")
    return tuple(QUOTED.findall(match.group("body")))


def web_bot_locales(repo: Path) -> tuple[str, ...]:
    return tuple(locale for locale in web_locales(repo) if locale not in WEB_SOURCE_LOCALES)


def flatten(value: object, prefix: str = "") -> dict[str, object]:
    """Nested message objects to dotted keys; strings and arrays are leaves."""
    out: dict[str, object] = {}
    if isinstance(value, dict):
        for key, child in value.items():
            out.update(flatten(child, f"{prefix}.{key}" if prefix else str(key)))
    elif prefix:
        out[prefix] = value
    return out


def english_only(state: dict, locale: str, key: str) -> bool:
    prefixes = [prefix for locales, group in state.get("englishOnly", {}).items()
                if locales == "*" or locale in locales.split() for prefix in group]
    return any(key == prefix or key.startswith(prefix + ".") for prefix in prefixes)


def write_json(path: Path, value: dict) -> None:
    CATALOG.atomic_write(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


# ---------------------------------------------------------------- gaps

def web_gaps(repo: Path, state: dict, previous: str) -> list[dict]:
    english = flatten(json.loads((repo / WEB_DIR / "en.json").read_text(encoding="utf-8")))
    old_text = show(repo, previous, f"{WEB_DIR}/en.json")
    old_english = flatten(json.loads(old_text)) if old_text else {}
    rows = []
    for locale in web_bot_locales(repo):
        path = repo / WEB_DIR / f"{locale}.json"
        if not path.is_file():
            continue
        localized = flatten(json.loads(path.read_text(encoding="utf-8")))
        old_localized_text = show(repo, previous, f"{WEB_DIR}/{locale}.json")
        old_localized = flatten(json.loads(old_localized_text)) if old_localized_text else {}
        for key, source in english.items():
            if english_only(state, locale, key):
                continue
            current = localized.get(key)
            if current is None:
                issue = "missing"
            elif (key in old_english and old_english[key] != source and key in old_localized
                  and old_localized[key] == current):
                issue = "English changed; retranslate"
            else:
                continue
            row = {"kind": "web", "catalog": f"{WEB_DIR}/{locale}.json", "locale": locale, "key": key,
                   "source": source, "issue": issue}
            if current is not None:
                row["current"] = current
                row["previousSource"] = old_english[key]
            rows.append(row)
    return rows


def macos_gaps(repo: Path, state: dict, previous: str) -> list[dict]:
    omissions = CATALOG.load_metadata("localization-allowed-omissions.json")
    counts = CATALOG.load_metadata("localization-plurals.json")
    rows = []
    for path in CATALOG.discover(repo):
        relative = str(path.relative_to(repo))
        old_text = show(repo, previous, relative)
        old = {}
        if old_text:
            try:
                old = {entry.key: entry.value for entry in CATALOG.catalog_entries(old_text)}
            except ValueError:
                old = {}
        for entry in CATALOG.catalog_entries(path.read_text(encoding="utf-8")):
            english = CATALOG.source(entry.value)
            localizations = entry.value.get("localizations", {})
            for locale in CATALOG.BOT_LOCALES:
                errors = CATALOG.check_entry(entry, locale, omissions, counts)
                current = localizations.get(locale)
                previous_entry = old.get(entry.key)
                if not errors and current is not None and previous_entry is not None:
                    try:
                        changed = CATALOG.canonical_text(CATALOG.source(previous_entry)) != CATALOG.canonical_text(english)
                    except ValueError:
                        changed = False
                    if changed and previous_entry.get("localizations", {}).get(locale) == current:
                        errors = ["English changed; retranslate"]
                if not errors:
                    continue
                row = {"kind": "macos", "catalog": relative, "locale": locale, "key": entry.key, "source": english,
                       "issue": "; ".join(errors), "comment": entry.value.get("comment"),
                       "placeholders": CATALOG.placeholders(english)}
                english_localization = localizations.get("en", {})
                if "variations" in english_localization or "substitutions" in english_localization:
                    row["englishLocalization"] = english_localization
                if current is not None:
                    row["current"] = current
                rows.append(row)
    return rows


PROMPT = """You translate user interface strings for cmux, a macOS terminal and agent workspace app, and its website.
Each row below is one string in one locale. Translate `source` (English) into the row's `locale`.

Rules:
- Keep every placeholder exactly: printf specifiers (%@, %d, %1$@, %lld), ICU arguments ({name},
  {count, plural, ...} with the same argument names and plural syntax), and rich-text tags (<b>...</b>, <link>...</link>).
- Keep product names, commands, code, paths, URLs, keyboard shortcuts and brand names (cmux, Claude, GitHub) as is.
- Keep line breaks. Match the tone and length of the English; use the locale's usual UI terminology.
- A row with `current` had a translation for an older English text (`previousSource`); update it to the new source.
- `value`: the translated string (an array of strings when `source` is an array, same length).
- A macOS row with `englishLocalization` (plural variations or substitutions): return `localization` instead, the
  same structure as englishLocalization with every stringUnit translated and "state": "translated", plural
  categories valid for the locale.
- Skip a row (leave it out) rather than guess when it cannot be translated faithfully.

Answer with the structured output only: {"translations": [{"id": <row id>, "value": ...} or {"id": ..., "localization": {...}}]}.

Rows (JSON):
"""


def gaps(repo: Path, out: Path, prompt_out: Path | None, limit: int) -> dict:
    state = load_state(repo)
    previous = state.get("filledThrough", "")
    if previous and git(repo, "cat-file", "-t", previous, check=False).strip() != "commit":
        previous = ""  # not fetched: no stale detection this run; missing keys still fill
    rows = macos_gaps(repo, state, previous) + web_gaps(repo, state, previous)
    chosen, size = [], 0
    for row in rows:
        encoded = len(json.dumps(row, ensure_ascii=False))
        if len(chosen) >= limit or size + encoded > PROMPT_BUDGET:
            break
        chosen.append(dict(row, id=len(chosen)))
        size += encoded
    head = git(repo, "rev-parse", "HEAD").strip()
    packet = {"version": 1, "head": head, "previous": previous, "total": len(rows),
              "complete": len(chosen) == len(rows), "entries": chosen}
    out.write_text(json.dumps(packet, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if prompt_out:
        prompt_out.write_text(PROMPT + json.dumps(chosen, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return packet


# ---------------------------------------------------------------- apply

def web_problems(source: object, value: object) -> list[str]:
    if isinstance(source, list):
        if not isinstance(value, list) or len(value) != len(source):
            return ["array length differs from English"]
        return [problem for left, right in zip(source, value) for problem in web_problems(left, right)]
    if not isinstance(source, str):
        return [] if value == source else ["non-string leaf changed"]
    if not isinstance(value, str) or not value.strip():
        return ["empty or non-string translation"]
    problems = []
    if not set(ICU_ARGUMENT.findall(source)) <= set(ICU_ARGUMENT.findall(value)):
        problems.append("ICU arguments differ from English")
    if sorted(TAG.findall(source)) != sorted(TAG.findall(value)):
        problems.append("rich-text tags differ from English")
    if value.count("{") != value.count("}"):
        problems.append("unbalanced braces")
    if CATALOG.MARKER.search(value) or CATALOG.BIDI.search(value):
        problems.append("unfinished marker or bidi control")
    return problems


def insert(target: dict, english: dict, parts: list[str], value: object) -> None:
    """Set a dotted key, placing a new key after its nearest English predecessor that the locale has."""
    head, rest = parts[0], parts[1:]
    if head in target:
        if rest:
            if not isinstance(target[head], dict):
                raise ValueError(f"{head}: locale has a leaf where English has an object")
            insert(target[head], english.get(head, {}), rest, value)
        else:
            target[head] = value
        return
    child: object = value
    if rest:
        child = {}
        insert(child, english.get(head, {}), rest, value)
    order = list(english.keys())
    position = order.index(head) if head in order else len(order)
    before = {key for key in order[:position]}
    items = list(target.items())
    at = 0
    for index, (key, _) in enumerate(items):
        if key in before:
            at = index + 1
    items.insert(at, (head, child))
    target.clear()
    target.update(items)


def apply(repo: Path, packet: dict, answer: dict) -> dict:
    rows = {str(row["id"]): row for row in packet.get("entries", [])}
    translations = answer.get("translations") if isinstance(answer, dict) else None
    if not isinstance(translations, list):
        raise ValueError("translator answer has no translations list")
    allowed_web = {f"{WEB_DIR}/{locale}.json" for locale in web_bot_locales(repo)}
    allowed_catalogs = {str(path.relative_to(repo)) for path in CATALOG.discover(repo)}
    omissions = CATALOG.load_metadata("localization-allowed-omissions.json")
    english_web = json.loads((repo / WEB_DIR / "en.json").read_text(encoding="utf-8"))
    web_files: dict[str, dict] = {}
    macos: dict[tuple[str, str], list[dict]] = {}
    applied, rejected = 0, []
    for item in translations:
        row = rows.get(str(item.get("id"))) if isinstance(item, dict) else None
        if row is None:
            continue
        if row["kind"] == "web":
            if row["catalog"] not in allowed_web or "value" not in item:
                rejected.append(f"{row['catalog']}:{row['key']}: not a bot web locale or no value")
                continue
            problems = web_problems(row["source"], item["value"])
            if problems:
                rejected.append(f"{row['catalog']}:{row['key']}: {'; '.join(problems)}")
                continue
            document = web_files.setdefault(row["catalog"], json.loads((repo / row["catalog"]).read_text(encoding="utf-8")))
            try:
                insert(document, english_web, row["key"].split("."), item["value"])
            except ValueError as error:
                rejected.append(f"{row['catalog']}:{row['key']}: {error}")
                continue
            applied += 1
        elif row["kind"] == "macos" and row["catalog"] in allowed_catalogs and row["locale"] in CATALOG.BOT_LOCALES:
            merged = {"key": row["key"], "source": row["source"]}
            if isinstance(item.get("localization"), dict):
                merged["localization"] = item["localization"]
            elif isinstance(item.get("value"), str) and "englishLocalization" not in row:
                merged["value"] = item["value"]
                if "current" in row and ("variations" in row["current"] or "substitutions" in row["current"]):
                    rejected.append(f"{row['catalog']}:{row['key']}:{row['locale']}: needs a full localization")
                    continue
            else:
                rejected.append(f"{row['catalog']}:{row['key']}:{row['locale']}: no usable translation")
                continue
            macos.setdefault((row["catalog"], row["locale"]), []).append(merged)
    for name, document in web_files.items():
        write_json(repo / name, document)
    for (catalog, locale), merged_rows in sorted(macos.items()):
        path = repo / catalog
        text = path.read_text(encoding="utf-8")
        for merged in merged_rows:
            # One row at a time: a rejected translation never blocks the others.
            try:
                text, changes = CATALOG.merge_text(text, locale, [merged], omissions)
            except ValueError as error:
                rejected.append(f"{catalog}:{merged['key']}:{locale}: {error}")
                continue
            applied += bool(changes)
        if text != path.read_text(encoding="utf-8"):
            CATALOG.atomic_write(path, text)
    state = load_state(repo)
    if packet.get("complete") and not rejected and len(translations) >= len(rows):
        state["filledThrough"] = packet["head"]
        write_json(repo / STATE, state)
    return {"applied": applied, "rejected": rejected}


# ---------------------------------------------------------------- open

def gh_api(path: str, *, method: str = "GET", fields: dict | None = None):
    argv = ["gh", "api", "-X", method, path] + (["--input", "-"] if fields is not None else [])
    for attempt in range(4):
        out = subprocess.run(argv, input=json.dumps(fields) if fields is not None else None, capture_output=True, text=True)
        if out.returncode == 0:
            return json.loads(out.stdout) if out.stdout.strip() else None
        if attempt == 3 or not re.search(r"HTTP 5\d\d|timeout|connection reset|rate limit", out.stderr, re.I):
            raise RuntimeError(f"gh api {method} {path}: {out.stderr.strip()[-400:]}")
        time.sleep(5 * (attempt + 1))
    return None


def redact(text: str) -> str:
    return re.sub(r"x-access-token:[^@\s]+@", "x-access-token:***@", text)


def open_pr(repo: Path, push_url: str, slug: str, base: str, summary: str) -> dict:
    files = [line for line in git(repo, "status", "--porcelain").splitlines() if line.strip()]
    if not files:
        return {"action": "none", "why": "nothing to fill"}
    git(repo, "add", "--", WEB_DIR, STATE, *[str(p.relative_to(repo)) for p in CATALOG.discover(repo)])
    title = "chore(i18n): fill non-source locales (localization-fill)"
    git(repo, "-c", f"user.name={BOT[0]}", "-c", f"user.email={BOT[1]}", "commit", "--quiet", "-m",
        f"{title}\n\n{summary}")
    sha = git(repo, "rev-parse", "HEAD").strip()
    pushed = subprocess.run(["git", "push", "--force", "--quiet", push_url, f"HEAD:refs/heads/{BRANCH}"], cwd=repo,
                            capture_output=True, text=True)
    if pushed.returncode:
        return {"action": "none", "why": "push refused: " + redact(pushed.stderr)[-600:]}
    owner = slug.split("/")[0]
    body = ("Translations for the locales that pull requests no longer write (every locale but English and "
            "Japanese), filled on main by .github/workflows/localization-fill.yml (scripts/localization_fill.py). "
            "Until this lands, those strings fall back to English.\n\n" + summary + "\n\n"
            "Leo, 2026-11-24: \"thinking of better architectures overall in order for us to parallelize more work "
            "and to do more as an agentic organization\".\n\n## Changelog\nnone\n")
    existing = gh_api(f"repos/{slug}/pulls?state=open&head={owner}:{BRANCH}&base={base}&per_page=5") or []
    if existing:
        number = existing[0]["number"]
        gh_api(f"repos/{slug}/pulls/{number}", method="PATCH", fields={"title": title, "body": body})
    else:
        created = gh_api(f"repos/{slug}/pulls", method="POST",
                         fields={"head": BRANCH, "base": base, "title": title, "body": body}) or {}
        number = created.get("number")
    return {"action": "opened", "number": number, "sha": sha}


# ---------------------------------------------------------------- cli

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("gaps", "apply", "open"))
    parser.add_argument("--repo-dir", type=Path, default=SCRIPT_DIR.parent)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--prompt-out", type=Path)
    parser.add_argument("--limit", type=int, default=LIMIT)
    parser.add_argument("--packet", type=Path)
    parser.add_argument("--answer", type=Path)
    parser.add_argument("--push-url")
    parser.add_argument("--repo")
    parser.add_argument("--base", default="main")
    parser.add_argument("--summary", default="")
    args = parser.parse_args(argv)
    repo = args.repo_dir.resolve()
    if args.command == "gaps":
        if not args.out:
            parser.error("gaps requires --out")
        packet = gaps(repo, args.out, args.prompt_out, args.limit)
        print(f"rows={len(packet['entries'])}")
        print(f"total={packet['total']}")
        return 0
    if args.command == "apply":
        if not args.packet or not args.answer:
            parser.error("apply requires --packet and --answer")
        packet = json.loads(args.packet.read_text(encoding="utf-8"))
        data = json.loads(args.answer.read_text(encoding="utf-8"))
        answer = data.get("structured_output") or data
        if "translations" not in answer and isinstance(data.get("result"), str):
            try:
                answer = json.loads(data["result"])
            except ValueError:
                answer = {}
        result = apply(repo, packet, answer)
        for line in result["rejected"][:50]:
            print(f"rejected: {line}", file=sys.stderr)
        print(f"applied={result['applied']}")
        print(f"rejected={len(result['rejected'])}")
        return 0
    if not args.push_url or not args.repo:
        parser.error("open requires --push-url and --repo")
    result = open_pr(repo, args.push_url, args.repo, args.base, args.summary)
    for key, value in result.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print(f"error: {redact(str(error))}", file=sys.stderr)
        raise SystemExit(2)

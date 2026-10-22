#!/usr/bin/env python3
"""THIRD_PARTY_LICENSES for the cmuxd-remote release binaries.

  remote_daemon_notices.py generate --daemon-root daemon/remote --out FILE [--update-review]
  remote_daemon_notices.py check --daemon-root daemon/remote [--update-review]

cmuxd-remote is built with CGO_ENABLED=0, so it links no libc: only the Go
standard library and runtime and its Go modules. `generate` lists the modules
the linux and darwin builds link (`go list -deps`), reads each module's license
files from the module cache (`go mod download -json`, which go.sum verifies)
and writes one text file with the Go texts and every module text.

daemon/remote/third-party/review.json records each module, its license and the
sha256 of each file. A dependency change never waits for a person when its
license is allowed (Leo, 2026-10-22: fix it, don't fail "without a review"):
  - a module whose files hash the same as a recorded entry (its own version or
    another of the same module) is approved by that entry;
  - any other module is approved when each of its license files is wholly a
    license on the allowlist (check_app_crate_licenses.ALLOWED, the app's crate
    allowlist): the whole text matches that license's SPDX template
    (third-party/spdx-templates), with only copyright lines where the template
    takes them, so an added clause is never approved. A NOTICE or PATENTS file
    is approved only when its text is already recorded (Go's PATENTS);
  - Go itself the same way, from GOROOT's license files, on every Go version;
  - a recorded entry still has to be on the allowlist, unless it carries an
    "approved" note: a person's approval of a license off the list.
Anything else (an unknown text, a disallowed license, an unrecognised notice)
fails, naming the module, the file and the license. Approvals the record does not have yet, and entries for modules
the build no longer links, are notes; `--update-review` writes the record.
`check` is the fast guard (cmux-next-remote-daemon.yml, on pull requests and
feat-cmux-next pushes): it prints the notes as warnings and fails only where
`generate` would. build_remote_daemon_release_assets.sh writes the file as
cmuxd-remote-THIRD_PARTY_LICENSES[-<suffix>].txt beside the binaries. Python
3.9+ standard library only.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import List

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cmux-tui/build-support/notices"))
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import license_match  # noqa: E402
from check_app_crate_licenses import ALLOWED  # noqa: E402

THIRD_PARTY = ROOT / "daemon/remote/third-party"
TEXTS = THIRD_PARTY
REVIEW = THIRD_PARTY / "review.json"
LICENSE_NAME = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|PATENTS|UNLICENSE)([._-].*)?$", re.I)
NOTICE_NAME = re.compile(r"^(NOTICE|PATENTS)([._-].*)?$", re.I)
SPDX_TEMPLATES = THIRD_PARTY / "spdx-templates"
# What a template's variable parts may hold besides their SPDX pattern (Codex review of d869d36: a
# pattern alone let a restriction sit in a bullet, a holder's name or a line under the copyright).
# A list bullet: "1.", "(a)", "iv)", "-".
BULLET = re.compile(r"(\(?([0-9]{1,2}|[a-z]|[ivxl]{1,5})[.)]|[-*\u2022\u00b7])?")
# A license's own title line ("The MIT License (MIT)", "BSD 3-Clause License").
TITLE_LINE = re.compile(r"(the )?(mit|x11|isc|zlib|0bsd|bsd( zero[ -]clause| [23][ -]clause)?( new| simplified| revised)?|apache)"
                        r"( licen[cs]e)?( \((mit|isc|iscl|0bsd|expat|zlib)\))?( version [0-9.]+)?:?")
COPYRIGHT_LINE = re.compile(r"(portions )?(copyright\b|\(c\)|\u00a9) ?(\(c\)|\u00a9)?(?P<rest>.*)")
RESERVED = re.compile(r"all rights reserved\.?")
# A sentence break, except after a company or name abbreviation.
SENTENCE_BREAK = re.compile(r"(?<!\binc)(?<!\bltd)(?<!\bllc)(?<!\bco)(?<!\bcorp)(?<!\bjr)(?<!\bsr)(?<!\bst)(?<!\b[a-z])[.;:!?] +(?=\S)| [-\u2013\u2014]+ ")
# Words that start a clause and never stand in a name.
CLAUSE_WORD = re.compile(r"\b(who|whom|which|that|nor|not|no|may|must|shall|only|except|unless|without|if|but|you|your|use|used|sell|sold|resale|fee|fees|pay|paid|commercial|noncommercial|non-commercial|permit\w*|permission|requir\w*|payment|royalt\w*|consent|approv\w*|agree\w*|prohibit\w*|forbid\w*|restrict\w*|condition\w*|terms|grant\w*|licen[cs]\w*|warrant\w*|liab\w*|redistribut\w*|modif\w*|distribut\w*)\b")
CORPORATE_COMMA = re.compile(r", (inc|ltd|llc|co|corp|gmbh|s\.a|b\.v|l\.p|plc)\b\.?")
NAME_WORDS = 10
# Signatures that only qualify an allowed license (Apache-2.0 WITH LLVM-exception).
EXCEPTIONS = {"LLVM-exception"}
PLATFORMS = (("linux", "amd64"), ("linux", "arm64"), ("darwin", "amd64"), ("darwin", "arm64"))


class NoticeError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class Module:
    path: str
    version: str
    directory: Path


def load_review() -> dict:
    return json.loads(REVIEW.read_text(encoding="utf-8"))


def _text(data: bytes, label: str) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise NoticeError(f"{label} is not UTF-8") from None


def license_digests(directory: Path) -> dict:
    """The sha256 of every license file in a directory (a module, or GOROOT)."""
    names = sorted(p.name for p in directory.iterdir() if p.is_file() and LICENSE_NAME.match(p.name))
    return {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in names}


def normalize(text: str) -> str:
    """SPDX matching: case, quotes, dashes, comment markers and whitespace do not count."""
    text = text.lower().replace("\u2019", "'").replace("\u2018", "'").replace("\u201c", '"').replace("\u201d", '"')
    text = re.sub("[\u2010-\u2015]", "-", text)
    text = re.sub(r"(?m)^[ \t]*(?://+|#+|\*+|>+)", " ", text)
    # Lines stay: a copyright part is checked line by line.
    lines = (re.sub(r"\s+", " ", line).strip() for line in text.splitlines())
    return "\n".join(line for line in lines if line)


SPDX_TOKEN = re.compile(r"<<(beginOptional|endOptional)(?:;[^>]*)?>>|<<var;(.*?)>>", re.S)
# Punctuation is a word of its own, so "conditions:" and "conditions :" compare equal.
WORD = re.compile(r"[a-z0-9]+(?:['.][a-z0-9]+)*|[^\sa-z0-9]")
# A variable part with no bound in its pattern spans at most this many characters.
VAR_CHARS = 5000


def words(normalized: str) -> list:
    return [(match.group(), match.start(), match.end()) for match in WORD.finditer(normalized)]


def parse_template(template: str) -> list:
    """An SPDX license template as nodes: ("word", w), ("var", name, pattern,
    max characters) and ("optional", nodes)."""
    root: list = []
    stack = [root]
    pos = 0
    for match in SPDX_TOKEN.finditer(template):
        stack[-1].extend(("word", w) for w, _, _ in words(normalize(template[pos:match.start()])))
        pos = match.end()
        if match.group(1) == "beginOptional":
            stack[-1].append(("optional", []))
            stack.append(stack[-1][-1][1])
        elif match.group(1) == "endOptional":
            stack.pop()
        else:
            attrs = dict(re.findall(r'(\w+)="((?:[^"\\]|\\.)*)"', match.group(2)))
            pattern = attrs.get("match", ".{0,5000}")
            bound = re.fullmatch(r"\.\{0,(\d+)\}", pattern)
            limit = int(bound.group(1)) if bound else VAR_CHARS
            stack[-1].append(("var", attrs.get("name", ""), re.compile(pattern, re.I | re.S), limit))
    stack[-1].extend(("word", w) for w, _, _ in words(normalize(template[pos:])))
    return root


def free_part(name: str, pattern: re.Pattern) -> bool:
    """A variable whose text a person may want to see: the copyright part or a free `.+`/`.*` one."""
    return name == "copyright" or bool(re.search(r"(?<!\\)\.[+*]", pattern.pattern))


def template_matches(nodes: list, normalized: str) -> tuple | None:
    """The free spans of one way the whole text matches the template, or None. It walks
    the word positions each node can end at, each with the free spans of one path there,
    so it never backtracks: a regex of Apache-2.0's template took minutes on a text with
    an added clause."""
    tokens = words(normalized)

    def span(start: int, end: int) -> str:
        return normalized[tokens[start][1]:tokens[end - 1][2]] if end > start else ""

    def advance(seq: list, positions: dict) -> dict:
        previous = None
        for node in seq:
            # Apache-2.0's template says "Copyright <<var>>": its holder is checked with the word.
            after_copyright, previous = previous == ("word", "copyright"), node
            if not positions:
                break
            if node[0] == "word":
                positions = {p + 1: spans for p, spans in positions.items() if p < len(tokens) and tokens[p][0] == node[1]}
            elif node[0] == "optional":
                positions = {**advance(node[1], positions), **positions}
            else:
                _, name, pattern, limit = node
                reached: dict = {}
                for start, spans in positions.items():
                    for end in range(start, len(tokens) + 1):
                        text = span(start, end)
                        if len(text) > limit:
                            break
                        if end not in reached and variable_holds(name, pattern, span(start - 1, end) if after_copyright else text):
                            reached[end] = spans + ((name, text),) if free_part(name, pattern) and text else spans
                positions = reached
        return positions

    return advance(nodes, {0: ()}).get(len(tokens))


_TEMPLATES: dict = {}


def templates() -> dict:
    if not _TEMPLATES:
        for path in sorted(SPDX_TEMPLATES.glob("*.template.txt")):
            _TEMPLATES[path.name[: -len(".template.txt")]] = parse_template(path.read_text(encoding="utf-8"))
    return {spdx: nodes for spdx, nodes in _TEMPLATES.items() if spdx in ALLOWED}


def a_name(text: str, words: int = NAME_WORDS) -> bool:
    """A holder's name, a year list or an address: no sentence, no clause, at most a few words."""
    text = text.strip(" .")
    return (len(text.split()) <= words and not SENTENCE_BREAK.search(text) and not CLAUSE_WORD.search(text)
            and "," not in CORPORATE_COMMA.sub("", text) or bool(re.fullmatch(r"[0-9 ,-]*", text)))


def copyright_block(span: str) -> bool:
    """A template's copyright part: a title line, then copyright lines, each a copyright marker,
    years and names, and "All rights reserved"; nothing else, on any line."""
    for line in span.split("\n"):
        line = line.strip()
        if not re.search(r"[a-z0-9]", line) or TITLE_LINE.fullmatch(line) or RESERVED.fullmatch(line):
            continue
        match = COPYRIGHT_LINE.fullmatch(line)
        if not match:
            return False
        rest = RESERVED.sub("", match.group("rest")).strip(" .")
        if not a_name(rest, words=24) and not all(a_name(part, words=12) for part in rest.split(",")):
            return False
    return True


def variable_holds(name: str, pattern: re.Pattern, text: str) -> bool:
    """Whether a template variable's span is its SPDX pattern and only the part it stands for."""
    flat = text.replace("\n", " ")
    # Whitespace at a variable's edge does not count: BSD's theme is "( of the theme)".
    if not any(pattern.fullmatch(variant) for variant in (flat, " " + flat, flat + " ", " " + flat + " ")):
        return False
    if name == "bullet":
        return bool(BULLET.fullmatch(flat))
    if name == "copyright":
        return copyright_block(text)
    if re.search(r"(?<!\\)\.[+*]", pattern.pattern):
        # A free part (a holder, an author, the organization of BSD's third clause, a contact): only
        # the words its pattern leaves free must be a name.
        count = iter(range(1000))
        free = re.compile(re.sub(r"(?<!\\)\.([+*])", lambda m: f"(?P<free{next(count)}>.{m.group(1)}?)", pattern.pattern), re.I | re.S)
        for variant in (flat, " " + flat, flat + " ", " " + flat + " "):
            match = free.fullmatch(variant)
            if match:
                return all(a_name(part) for part in match.groupdict().values() if part)
        return False
    return True


def match_license(text: str) -> tuple:
    """(the allowed SPDX id this text wholly is, or None; the free spans it matched with)."""
    normalized = normalize(text)
    for spdx, nodes in templates().items():
        spans = template_matches(nodes, normalized)
        if spans is not None:
            return spdx, spans
    return None, ()


def allowed_license(text: str) -> str | None:
    return match_license(text)[0]


def license_ids(expression: str) -> set:
    return set(re.findall(r"[A-Za-z0-9.+-]+", expression)) - {"AND", "OR", "WITH"}


def recorded_allowed(entry: dict) -> bool:
    return not (license_ids(entry["license"]) - set(ALLOWED) - EXCEPTIONS) or bool(entry.get("approved"))


def check_recorded(label: str, entry: dict) -> None:
    if not recorded_allowed(entry):
        raise NoticeError(f"{label}: its recorded license {entry['license']} is not on the allowlist (scripts/cmux-next/check_app_crate_licenses.py ALLOWED); a person approves it with an \"approved\" note in daemon/remote/third-party/review.json")


def recorded_notices(review: dict) -> set:
    """The NOTICE and PATENTS texts of recorded entries still allowed: a person or this check
    approved each (Go's PATENTS). A license text is never approved this way, only by its template."""
    return {digest for entry in [review["go"], *review["modules"].values()] if recorded_allowed(entry)
            for name, digest in entry["files"].items() if NOTICE_NAME.match(name)}


def classify(directory: Path, label: str, known: set = frozenset()) -> str:
    """The license of a directory's license files, when each is wholly an allowed
    license or a recorded text; otherwise the error names what a person reviews."""
    digests = license_digests(directory)
    if not [name for name in digests if not NOTICE_NAME.match(name)]:
        raise NoticeError(f"{label} ships no license file ({', '.join(digests) or 'none'}); a person reviews it")
    ids = set()
    for name, digest in digests.items():
        text = _text((directory / name).read_bytes(), f"{label} {name}")
        spdx = allowed_license(text)
        if spdx:
            ids.add(spdx)
            continue
        if digest in known and NOTICE_NAME.match(name):
            continue
        refused = sorted(i for i in license_match.SIGNATURES if license_match.matches(i, text) and i not in ALLOWED and i not in EXCEPTIONS)
        if refused:
            raise NoticeError(f"{label}: {name} is {' and '.join(refused)}, which is not on the allowlist (scripts/cmux-next/check_app_crate_licenses.py ALLOWED); a person decides whether cmuxd-remote may ship it")
        raise NoticeError(f"{label}: {name} is not wholly a license on the allowlist (daemon/remote/third-party/spdx-templates) nor a recorded text; a person reviews it")
    if not ids:
        raise NoticeError(f"{label}: none of its license files ({', '.join(digests)}) is an allowed license; a person reviews it")
    return " AND ".join(sorted(ids))


def free_text(directory: Path) -> str:
    """The spans an automatic approval let through that its templates leave free (holders,
    copyright lines, BSD's organization), shown in its note: a template cannot prove them names."""
    shown = []
    for name in license_digests(directory):
        _, spans = match_license((directory / name).read_bytes().decode("utf-8", "replace"))
        shown += [f"{name} {part}: {text}" for part, text in spans]
    return "; ".join(shown).replace("\n", " / ") or "none"


def write_atomically(path: Path, text: str) -> None:
    """Replace a file only once its new text is fully written."""
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        temporary.write_text(text, encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def review_entry(module: Module, review: dict) -> tuple[str | None, dict]:
    """The recorded key that approves a module and its entry, or (None, a new
    entry) when its allowed license approves it."""
    key = f"{module.path}@{module.version}"
    digests = license_digests(module.directory)
    same_path = [k for k in sorted(review["modules"]) if k.rsplit("@", 1)[0] == module.path]
    for candidate in sorted(same_path, key=lambda k: k != key):
        if review["modules"][candidate]["files"] == digests:
            check_recorded(key, review["modules"][candidate])
            return candidate, review["modules"][candidate]
    return None, {"license": classify(module.directory, key, recorded_notices(review)), "files": digests}


def go_entry(go_version: str, review: dict, go_root: Path | None) -> tuple[bool, dict, Path]:
    """Whether review.json's Go entry approves this Go, the entry, and where its texts are."""
    go = review["go"]
    check_recorded(f"Go {go_version}", go)
    same_minor = bool(re.fullmatch(re.escape(go["minor"]) + r"(\.[0-9]+)?", go_version))
    minor = re.match(r"go[0-9]+\.[0-9]+", go_version)
    if go_root is None:
        if same_minor:
            return True, go, TEXTS / "go"
        raise NoticeError(f"cmuxd-remote is built with {go_version}, but review.json records {go['minor']} and GOROOT was not given")
    try:
        digests = license_digests(go_root)
    except OSError as error:
        raise NoticeError(f"Go {go_version}: cannot read GOROOT's license files ({error})") from None
    if digests == go["files"]:
        return same_minor, {**go, "minor": minor.group(0) if minor else go["minor"]}, TEXTS / "go"
    entry = {**{k: v for k, v in go.items() if k != "approved"}, "minor": minor.group(0) if minor else go_version,
             "license": classify(go_root, f"Go {go_version}", recorded_notices(review)),
             "files": digests, "source": f"LICENSE files of GOROOT ({go_version})"}
    return False, entry, go_root


def updated_review(modules: List[Module], review: dict, go_version: str | None = None, go_root: Path | None = None) -> dict:
    """review.json for what the build links: every module under its linked
    version, approvals recorded, entries for modules no longer linked gone."""
    entries = {f"{m.path}@{m.version}": review_entry(m, review)[1] for m in modules}
    go = go_entry(go_version, review, go_root)[1] if go_version else review["go"]
    return {**review, "go": go, "modules": dict(sorted(entries.items()))}


def dump_review(review: dict) -> str:
    """review.json's layout: one line per module."""
    head = json.dumps({k: v for k, v in review.items() if k != "modules"}, indent=2)[:-2]
    lines = [f"    {json.dumps(k)}: {json.dumps(v)}" for k, v in review["modules"].items()]
    return head + ',\n  "modules": {\n' + ",\n".join(lines) + "\n  }\n}\n"


def compose(modules: List[Module], go_version: str, review: dict, go_root: Path | None = None,
            notes: list | None = None) -> str:
    notes = [] if notes is None else notes
    recorded, go, go_texts = go_entry(go_version, review, go_root)
    if not recorded:
        notes.append(f"Go {go_version}: approved automatically ({go['license']}; free text: {free_text(go_texts)}); generate --update-review records it")
    out = [
        "Third-party notices for cmuxd-remote\n",
        "Generated by scripts/remote_daemon_notices.py; do not edit.\n\n",
        "cmuxd-remote is part of cmux (GPL-3.0-or-later). It is built with CGO_ENABLED=0 and statically\n",
        "contains the code below and no C library.\n\n",
        f"== Go standard library and runtime ({go_version}) ==\n",
        f"License: {go['license']}. Source: {go['source']}\n\n",
    ]
    for name, digest in sorted(go["files"].items()):
        data = (go_texts / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise NoticeError(f"daemon/remote/third-party/go/{name} does not match review.json")
        out += [f"--- go/{name} ---\n", _text(data, f"go/{name}").rstrip("\n") + "\n\n"]
    seen = set()
    used = set()
    for module in sorted(modules, key=lambda m: (m.path, m.version)):
        key = f"{module.path}@{module.version}"
        if key in seen:
            continue
        seen.add(key)
        reviewed, entry = review_entry(module, review)
        if reviewed is None:
            notes.append(f"{key}: approved automatically ({entry['license']}; free text: {free_text(module.directory)}); generate --update-review records it")
        else:
            used.add(reviewed)
        out.append(f"== {module.path} {module.version} ==\nLicense: {entry['license']}. Source: https://proxy.golang.org/{module.path}/@v/{module.version}.zip\n\n")
        for name in sorted(entry["files"]):
            data = (module.directory / name).read_bytes()
            out += [f"--- {name} ---\n", _text(data, f"{key} {name}").rstrip("\n") + "\n\n"]
    for key in sorted(set(review["modules"]) - used):
        if key not in seen:
            notes.append(f"{key}: no longer linked; generate --update-review drops its entry")
    return "".join(out)


def write_review_bundle(review_text: str, go_files: dict, go_texts: Path) -> None:
    """Write review.json and, when Go's texts changed, third-party/go together:
    the new texts are staged beside the old, swapped in, and swapped back if
    review.json cannot be written, so the two never disagree."""
    current = TEXTS / "go"
    if go_texts == current:
        write_atomically(REVIEW, review_text)
        return
    staged = TEXTS / f".go.new-{os.getpid()}"
    previous = TEXTS / f".go.old-{os.getpid()}"
    try:
        staged.mkdir()
        for name in go_files:
            shutil.copyfile(go_texts / name, staged / name)
        os.rename(current, previous)
        try:
            os.rename(staged, current)
            write_atomically(REVIEW, review_text)
        except BaseException:
            # Put the old texts back; if that fails too, they stay in `previous` for a person.
            if current.exists():
                shutil.rmtree(current)
            os.rename(previous, current)
            raise
        shutil.rmtree(previous)
    finally:
        shutil.rmtree(staged, ignore_errors=True)


def _go(daemon_root: Path, *args: str, env: dict | None = None) -> str:
    result = subprocess.run(["go", "-C", str(daemon_root), *args], capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise NoticeError(f"go {' '.join(args)} failed:\n{result.stderr}")
    return result.stdout


def linked_modules(daemon_root: Path) -> List[Module]:
    keys = set()
    for goos, goarch in PLATFORMS:
        env = {**os.environ, "GOOS": goos, "GOARCH": goarch, "CGO_ENABLED": "0"}
        listing = _go(daemon_root, "list", "-deps", "-f", "{{with .Module}}{{if not .Main}}{{.Path}}@{{.Version}}{{end}}{{end}}", "./cmd/cmuxd-remote", env=env)
        keys.update(line for line in listing.split() if line)
    modules = []
    for key in sorted(keys):
        info = json.loads(_go(daemon_root, "mod", "download", "-json", key))
        modules.append(Module(info["Path"], info["Version"], Path(info["Dir"])))
    return modules


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate", help="write the notices file")
    check = sub.add_parser("check", help="the fast guard: approve what is allowed, warn, fail only on a refused license")
    for command in (gen, check):
        command.add_argument("--daemon-root", type=Path, default=ROOT / "daemon/remote")
        command.add_argument("--update-review", action="store_true",
                             help="also rewrite review.json (and third-party/go) for what the build links")
    gen.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    notes: list = []
    try:
        go_version = _go(args.daemon_root, "env", "GOVERSION").strip()
        go_root = Path(_go(args.daemon_root, "env", "GOROOT").strip())
        modules = linked_modules(args.daemon_root)
        review = load_review()
        text = compose(modules, go_version, review, go_root=go_root, notes=notes)
        updated = updated_review(modules, review, go_version, go_root) if args.update_review else None
    except NoticeError as error:
        print(f"{'::error title=cmuxd-remote license::' if annotate else 'remote_daemon_notices: error: '}{error}", file=sys.stderr)
        return 1
    for note in notes:
        print(f"{'::warning title=cmuxd-remote license::' if annotate else 'remote_daemon_notices: note: '}{note}", file=sys.stderr)
    if args.command == "generate":
        args.out.write_text(text, encoding="utf-8")
        print(f"remote_daemon_notices: wrote {args.out} ({go_version})")
    if updated is not None:
        write_review_bundle(dump_review(updated), updated["go"]["files"], go_entry(go_version, review, go_root)[2])
        print(f"remote_daemon_notices: updated {REVIEW.relative_to(ROOT)}")
    if args.command == "check":
        print(f"remote_daemon_notices: every license cmuxd-remote links is allowed ({len(modules)} modules, {go_version})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

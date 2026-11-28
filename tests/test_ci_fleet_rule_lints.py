#!/usr/bin/env python3
"""Fleet rule lints: three rulebook rules, checked over every tracked file.

  keychain  The fleet sudo password (keychain service manaflow-fleet-sudo) is read only by the fleet's own
            sudo tool, which lives outside this repository: nothing here reads or names that item. Every
            keychain read in a script, workflow or tool counts, whatever service it names (a variable or
            config can hold the fleet one), so each reader is listed with the item it reads. Swift sources are
            the app's own keychain items (SecItemCopyMatching on its own services) and are not counted; the
            fleet item may still not be read or named anywhere (test_fleet_sudo_item_read_only_...).
  pkill     No pkill, killall, or kill fed by a name lookup (`kill $(pgrep ...)`, `pgrep ... | xargs kill`): "Kill only processes you started ... track your own PIDs or process group and
            signal those. Never `pkill`/`killall`, or `kill` PIDs found by name or pattern": a pattern also
            matches another run's app, test or build on a shared machine.
  big-red   Nothing depends on the personal Linux workstation of that name: it is not infrastructure. Prose
            (*.md, docs/) is exempt, so a doc may say "never there"; workflows, scripts, tools, install paths
            and code are not (a test fixture using the name as sample data is listed with that reason).

tests/fleet-rule-allowlist.json lists, per rule, the files allowed to match, each with the exact number of
matches (occurrences, not lines) and a reason. The test fails when a file not on the list matches, when a file has more matches
than its entry allows (a new violation), when it has fewer (lower the count, so the list only shrinks), and
when an entry is stale or has no reason. Entries whose reason starts with "debt:" are known violations to fix.

In CI, FLEET_RULE_BASE (or the guard runner's CMUX_GUARDS_BASE_SHA) names the base commit: an entry added or
raised since that commit's allowlist fails unless its reason starts with "safe:", so debt never grows and a PR
cannot allowlist its own new violation as debt. A genuinely safe new use (a kill of a process group the script
started itself, say) is added with its "safe:" entry in the same PR, where the reviewer sees the allowlist diff
beside the code it covers.
"""

from __future__ import annotations

import functools
import json
import os
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = Path(__file__).resolve().parent / "fleet-rule-allowlist.json"
SELF = {"tests/test_ci_fleet_rule_lints.py", "tests/fleet-rule-allowlist.json"}

KEYCHAIN_SERVICE = "manaflow-fleet-sudo"
KEYCHAIN_READ = re.compile(r"find-generic-password|SecItemCopyMatching|keyring\.get_password|get_generic_password")
# A kill whose PIDs a lookup supplies on the same command: `kill $(pgrep ...)`, `pgrep ... | xargs kill`.
PKILL_LOOKUP = re.compile(r"(?<![\w-])kill\b[^\n;|&]*\$\(\s*(?:pgrep|pidof)\b"
                          r"|(?<![\w-])(?:pgrep|pidof)\b[^\n;]*\|\s*xargs\b[^\n;|]*\bkill\b")
PKILL = re.compile(r"(?<![\w-])(?:pkill|killall)(?![\w-])|" + PKILL_LOOKUP.pattern)
# big-red, big_red, BIG_RED, bigred, Big Red; not prose like "a big red build".
BIG_RED = re.compile(r"(?<![A-Za-z0-9])(?:(?i:big[-_]?red)|Big Red|BIG RED)(?![A-Za-z0-9])")


def tracked_files() -> list[str]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p for p in out.decode().split("\0") if p]


# Every rule needs one of these words in the file, so fixed-string git greps narrow the tracked files to the
# few that can match before any regex runs (a regex grep over this repository takes seconds, a full read minutes).
CANDIDATE_WORDS = ("pkill", "killall", "pgrep", "pidof", "ps -a", "ps -A", "ps -e", "ps aux", "find-generic-password", "SecItemCopyMatching", "keyring",
                   "get_generic_password", "manaflow-fleet-sudo")
CANDIDATE_WORDS_ANY_CASE = ("big-red", "big_red", "bigred", "big red")


@functools.lru_cache(maxsize=1)
def candidate_files() -> tuple[str, ...]:
    found: set[str] = set()
    for flags, words in ((["-F"], CANDIDATE_WORDS), (["-F", "-i"], CANDIDATE_WORDS_ANY_CASE)):
        argv = ["git", "-C", str(ROOT), "grep", "-I", "-l", "-z", *flags]
        for word in words:
            argv += ["-e", word]
        p = subprocess.run(argv, capture_output=True)
        if p.returncode not in (0, 1):
            raise RuntimeError(p.stderr.decode(errors="replace"))
        found.update(rel for rel in p.stdout.decode().split("\0") if rel)
    return tuple(sorted(found))


def read_text(rel: str) -> str | None:
    path = ROOT / rel
    if path.is_symlink() or not path.is_file():
        return None
    try:
        return path.read_text()
    except (UnicodeDecodeError, OSError):
        return None


PROSE_SUFFIXES = (".md", ".mdx", ".txt", ".rst", ".adoc")


def prose(rel: str) -> bool:
    """Prose by extension only: a script or code file under docs/ is still checked."""
    return rel.endswith(PROSE_SUFFIXES)


# No file in this repository may read the fleet sudo item, and none outside prose may name it. Fixed here,
# not in the allowlist, so no PR can add a reader by editing a count.
FLEET_SUDO_READERS: set[str] = set()
FLEET_SUDO_NAMERS: set[str] = set()


def keychain_lines(text: str) -> int:
    """Keychain reads, whatever service they name."""
    return len(KEYCHAIN_READ.findall(text))


def reads_fleet_sudo(text: str) -> bool:
    return KEYCHAIN_SERVICE in text and bool(KEYCHAIN_READ.search(text))


# pgrep -P PID lists the children of a PID the script holds: its own, so not a lookup by name.
# A process listing (`ps -ax...`, `ps -e`, `ps aux`) is a lookup too; `ps -p PID` is not.
PS_LIST = r"ps\s+(?:-[A-Za-z]*[Aae][A-Za-z]*\b|aux\b)"
LOOKUP = re.compile(r"(?<![\w-])(?:pgrep(?!\s+-P\b)|pidof|" + PS_LIST + r")(?![\w-])")
KILL_WORD = re.compile(r"(?<![\w-])kill(?![\w-])")
_LOOKUP_CMD = r"\s*(?:sudo\s+(?:-\S+\s+)*)?(?:/usr/bin/|/bin/)?(?:pgrep(?!\s+-P\b)|pidof|" + PS_LIST + r")"
LOOKUP_FOR = re.compile(r"\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+[\"']?(?:\$\(|`)" + _LOOKUP_CMD)
LOOKUP_DONE = re.compile(r"\bdone\b\s*<\s*<\(" + _LOOKUP_CMD)
# x=$(pgrep ...), x=`pidof ...`, and the array form x=($(pgrep ...)).
LOOKUP_ASSIGN = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=\(?[\"']?(?:\$\(|`)" + _LOOKUP_CMD)
# for p in "${pids[@]}" / $pids: the loop variable carries the lookup's PIDs.
FOR_OVER = re.compile(r"\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+[^;]*?\$\{?([A-Za-z_][A-Za-z0-9_]*)")


def pkill_lines(text: str) -> int:
    """pkill/killall occurrences, plus each kill fed by a name lookup: a line with both pgrep/pidof and kill,
    a pgrep/pidof piped into a loop, and a kill of a variable a pgrep/pidof filled."""
    # A pipeline continued after a trailing | or a backslash is one logical line.
    text = re.sub(r"(\\|\|)[ \t]*\n\s*", lambda m: " " if m.group(1) == "\\" else "| ", text)
    n = len(PKILL.findall(text))
    lookup_vars: set[str] = set()
    piped = False  # inside `pgrep ... | while read` until its `done`
    for line in text.splitlines():
        lookup_vars.update(LOOKUP_ASSIGN.findall(line))
        lookup_vars.update(LOOKUP_FOR.findall(line))
        lookup_vars.update(v for v, src in FOR_OVER.findall(line) if src in lookup_vars)
        kills = len(KILL_WORD.findall(line))
        if LOOKUP.search(line):
            # A loop that opens and closes on this line ends here.
            opened = re.search(r"\|\s*while\b(.*)", line)
            if opened and not re.search(r"\bdone\b", opened.group(1)):
                piped = True
            # Every kill on a lookup line counts once: the ones PKILL_LOOKUP already counted are not added again.
            n += max(0, kills - len(PKILL_LOOKUP.findall(line)))
            continue
        if piped:
            n += kills
            if re.search(r"\bdone\b", line):
                piped = False
            continue
        if kills and any(re.search(r"\$\{?" + v + r"\b", line) for v in lookup_vars):
            n += kills
    # while ...; do kill ...; done < <(pgrep ...): the lookup comes after the body.
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if LOOKUP_DONE.search(line):
            j = i
            while j > 0 and not re.search(r"\bwhile\b", lines[j]):
                j -= 1
            # The lookup line itself was counted above.
            n += sum(len(KILL_WORD.findall(l)) for l in lines[j:i + 1] if not LOOKUP.search(l))
    return n


def big_red_lines(text: str) -> int:
    return len(BIG_RED.findall(text))


RULES = {
    "keychain": (keychain_lines, lambda rel: not rel.endswith(".swift")),
    "pkill": (pkill_lines, lambda rel: True),
    "big-red": (big_red_lines, lambda rel: not prose(rel)),
}

HOW = {
    "keychain": "nothing in this repository reads the fleet sudo password; the fleet's own sudo tool does",
    "pkill": "signal only processes you started, by recorded PID or process group (kill PID, kill -- -PGID, "
             "pkill -P PID of your own child); never pkill/killall by name or pattern",
    "big-red": "that is a personal machine: nothing (service, timer, runner, cache, default) may depend on it; "
               "use the fleet or Blacksmith",
}


def scan() -> dict[str, dict[str, int]]:
    found: dict[str, dict[str, int]] = {rule: {} for rule in RULES}
    for rel in candidate_files():
        if rel in SELF:
            continue
        text = read_text(rel)
        if text is None:
            continue
        for rule, (count, applies) in RULES.items():
            if applies(rel):
                n = count(text)
                if n:
                    found[rule][rel] = n
    return found


def base_ref() -> str:
    """The base commit, when CI names one this checkout holds."""
    base = (os.environ.get("FLEET_RULE_BASE") or os.environ.get("CMUX_GUARDS_BASE_SHA") or "").strip()
    if not base or set(base) == {"0"}:
        return ""
    p = subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{base}^{{commit}}"], capture_output=True)
    return base if p.returncode == 0 else ""


def base_allowlist() -> dict | None:
    """The allowlist at FLEET_RULE_BASE (CI's base commit), or None when unset or the base has none."""
    base = base_ref()
    if not base:
        return None
    p = subprocess.run(["git", "-C", str(ROOT), "show", f"{base}:{ALLOWLIST.relative_to(ROOT)}"],
                       capture_output=True, text=True)
    return json.loads(p.stdout) if p.returncode == 0 else None


def grown(base: dict, allow: dict, rule: str) -> list[str]:
    """Entries added or raised since the base allowlist whose reason is not "safe:": debt only shrinks."""
    out = []
    old = base.get(rule, {})
    for rel, entry in sorted(allow.get(rule, {}).items()):
        was = old.get(rel, {}).get("count", 0)
        if entry.get("count", 0) > was and not str(entry.get("reason", "")).startswith("safe:"):
            out.append(f"{rel}: allowlist {was} -> {entry.get('count')} since the base: debt only shrinks "
                       f"(a genuinely safe new use gets a reason starting with \"safe:\" that says why)")
    return out


class FleetRuleLints(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.allow = json.loads(ALLOWLIST.read_text())
        cls.base = base_allowlist()
        cls.found = scan()

    def check(self, rule: str):
        allowed = self.allow.get(rule, {})
        found = self.found[rule]
        problems = []
        # workflow): those entries may sit above their current count, or match nothing yet.
        for rel, n in sorted(found.items()):
            entry = allowed.get(rel)
            if entry is None:
                problems.append(f"{rel}: {n} new line(s) match; {HOW[rule]}")
            elif n > entry["count"]:
                problems.append(f"{rel}: {n} matching lines, allowlist says {entry['count']}: a new one; {HOW[rule]}")
            elif n < entry["count"]:
                problems.append(f"{rel}: {n} matching lines, allowlist says {entry['count']}: lower the count in "
                                f"tests/fleet-rule-allowlist.json (it only shrinks)")
        for rel, entry in sorted(allowed.items()):
            count = entry.get("count")
            if type(count) is not int or count < 1:
                problems.append(f"{rel}: allowlist count must be a positive integer, not {count!r}")
            if rel not in found:
                problems.append(f"{rel}: allowlisted but no longer matches; remove its entry")
            if not re.match(r"(safe|debt): \S", str(entry.get("reason", ""))):
                problems.append(f"{rel}: allowlist reason must start with \"safe: \" or \"debt: \" and say why")
        if self.base is not None:
            problems += grown(self.base, self.allow, rule)
        self.assertEqual(problems, [], f"{rule} lint ({HOW[rule]}):\n  " + "\n  ".join(problems))

    def test_keychain(self):
        self.check("keychain")

    def test_fleet_sudo_item_read_only_by_the_sanctioned_readers(self):
        bad = []
        for rel in candidate_files():
            if rel in SELF or rel in FLEET_SUDO_READERS:
                continue
            text = read_text(rel)
            if text is not None and reads_fleet_sudo(text):
                bad.append(rel)
            elif text is not None and KEYCHAIN_SERVICE in text and not prose(rel) and rel not in FLEET_SUDO_NAMERS:
                bad.append(f"{rel} (names the item)")
        self.assertEqual(bad, [], HOW["keychain"])

    def test_pkill(self):
        self.check("pkill")

    def test_big_red(self):
        self.check("big-red")

    def test_only_known_rules(self):
        self.assertEqual(set(self.allow) - set(RULES), set())


class Patterns(unittest.TestCase):
    def test_keychain_catches_direct_reads(self):
        for text in ('security find-generic-password -s manaflow-fleet-sudo -w',
                     'subprocess.run(["security", "find-generic-password", "-s", "manaflow-fleet-sudo", "-w"])',
                     'SVC=manaflow-fleet-sudo\npw=$(security find-generic-password -s "$SVC" -w)'):
            self.assertGreater(keychain_lines(text), 0, text)
        self.assertEqual(keychain_lines("fleet-sudo HOST 'true'  # manaflow-fleet-sudo stays in the keychain"), 0)
        self.assertEqual(keychain_lines('svc = cfg["service"]\nrun(["security", "find-generic-password", "-s", svc])'), 1)
        self.assertTrue(reads_fleet_sudo('KEYCHAIN_SERVICE = "manaflow-fleet-sudo"\nrun(["security", "find-generic-password"])'))
        self.assertFalse(reads_fleet_sudo('KEYCHAIN_SERVICE = "cmuxterm-circleci"\nrun(["security", "find-generic-password"])'))

    def test_pkill_catches_kills_by_name(self):
        for line in ('pkill -f "cmux DEV"', "killall Dock", "sudo pkill -x tccd",
                     'subprocess.run(["/usr/bin/pkill", "-9", "x"])', 'exec.Command("pkill", "-f", tag)'):
            self.assertEqual(pkill_lines(line), 1, line)
        for line in ("kill $(pgrep -f foo)", "pgrep -x Dock | xargs kill -9", "kill -9 $( pidof meshline )"):
            self.assertEqual(pkill_lines(line), 1, line)
        self.assertEqual(pkill_lines("pkill -x a; pkill -x b"), 2)
        self.assertEqual(pkill_lines('p=$(pgrep x)\nkill -STOP "$p"; kill -CONT "$p"'), 2)
        for text in ('pids="$(pgrep -f foo)"\nkill "$pids"', "p=`pidof x`\nkill -9 $p",
                     "pgrep -f foo | while read -r p; do\n  kill $p\ndone",
                     'pids=$(pgrep -f x || true); [ -z "$pids" ] || printf "%s\\n" "$pids" | xargs kill -9',
                     'for p in $(pgrep -f foo); do\n  kill "$p"\ndone',
                     'while read -r pid; do\n  kill "$pid"\ndone < <(pgrep -f foo)'):
            self.assertGreaterEqual(pkill_lines(text), 1, text)
        self.assertEqual(pkill_lines('w="$(pgrep -P "$pid" | head -1)"\nkill -TERM "$w"'), 0)
        for line in ("kill -TERM -- -$pgid", "pkill_guard_test", "nx-pkill-shim", "skill", 'kill "$(cat pidfile)"',
                     "pgrep -f x >/dev/null && echo running"):
            self.assertEqual(pkill_lines(line), 0, line)

    def test_shrink_only_against_the_base(self):
        base = {"pkill": {"a.sh": {"count": 2, "reason": "r"}}}
        self.assertEqual(grown(base, {"pkill": {"a.sh": {"count": 1, "reason": "r"}}}, "pkill"), [])
        self.assertEqual(len(grown(base, {"pkill": {"a.sh": {"count": 3, "reason": "r"}}}, "pkill")), 1)
        self.assertEqual(len(grown(base, {"pkill": {"b.sh": {"count": 1, "reason": "r"}}}, "pkill")), 1)
        self.assertEqual(len(grown(base, {"pkill": {"b.sh": {"count": 1, "reason": "debt: x"}}}, "pkill")), 1)
        self.assertEqual(grown(base, {"pkill": {"a.sh": {"count": 3, "reason": "safe: own pgid"}}}, "pkill"), [])

    def test_big_red_catches_the_names(self):
        for line in ("runs-on: big-red-owned-linux", "ssh big-red true", "BIG_RED_HOST=1", "Big Red"):
            self.assertEqual(big_red_lines(line), 1, line)
        self.assertEqual(big_red_lines("bigredundant"), 0)
        self.assertEqual(big_red_lines("a smaller green landing beats a big red one"), 0)
        self.assertTrue(prose("knowledge/x.md") and prose("docs/a.txt") and not prose("scripts/a.sh"))
        self.assertFalse(prose("docs/tool.py") or prose("docs/run.sh"))

    def test_pkill_counts_each_kill_once(self):
        self.assertEqual(pkill_lines('pgrep -f worker | while read -r p; do\n  printf "%s\\n" "$p"\ndone'), 0)
        self.assertEqual(pkill_lines('pgrep -f worker | while read -r p; do\n  kill "$p"\ndone'), 1)
        self.assertEqual(pkill_lines('while read -r p; do kill "$p"; done < <(pgrep -f worker)'), 1)
        self.assertEqual(pkill_lines('while read -r p; do\n  kill "$p"\ndone < <(pgrep -f worker)'), 1)
        self.assertEqual(pkill_lines('pgrep -f worker |\n  while read -r p; do\n  kill "$p"\ndone'), 1)
        self.assertEqual(pkill_lines('pgrep -f worker \\\n  | xargs kill'), 1)
        self.assertEqual(pkill_lines('p=$(pgrep -f foo); pkill -x bar; kill "$p"'), 2)
        self.assertEqual(pkill_lines('PIDS=($(pgrep -f app))\nfor PID in "${PIDS[@]}"; do\n  kill "$PID"\ndone'), 1)
        self.assertEqual(pkill_lines('while read -r pid; do\n  kill "$pid"\ndone < <(ps -axo pid=,command= | awk \'/x/ {print $1}\')'), 1)
        self.assertEqual(pkill_lines('ps aux | grep x | awk \'{print $2}\' | xargs kill'), 1)
        self.assertEqual(pkill_lines('age=$(ps -o etimes= -p "$pid")\nkill "$pid"'), 0)
        self.assertEqual(pkill_lines('kill $(pgrep -f foo); pkill helper'), 2)
        self.assertEqual(pkill_lines('pgrep worker | while read p; do echo "$p"; done\nkill "$owned_pid"'), 0)
        self.assertEqual(pkill_lines('pgrep worker | while read p; do kill "$p"; done\nkill "$owned_pid"'), 1)


if __name__ == "__main__":
    unittest.main()

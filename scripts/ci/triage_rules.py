#!/usr/bin/env python3
"""One source of truth for cmux severity and area labels.

The severity vocabulary started in `triage-radar.py`, which scores recent
issues for the attention feed. Auto-triage needs the same judgement to put a
label on an issue, so the patterns live here and both import them. A second,
disagreeing copy would mean the radar and the labels tell different stories
about the same report.

Every decision this module returns carries the rule name that produced it, so
a bot comment can say why and a human can argue with the rule rather than with
the bot. `docs/triage.md` is the prose version of what follows.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterable


SEVERITY_ORDER = ["S1: critical", "S2: major", "S3: minor", "S4: cosmetic"]
NEEDS_TRIAGE = "needs-triage"
AREA_PREFIX = "area: "

# Kept at module scope under this name because triage-radar.py scores with it.
HIGH_RISK_PATTERNS: list[tuple[re.Pattern[str], int, str]] = [
    (re.compile(r"\b(crash(?:es|ed|ing)?|panic)\b", re.I), 6, "crash/panic"),
    (re.compile(r"\b(deadlock|freeze[sd]?|frozen|hang(?:s|ing)?)\b", re.I), 5, "hang/freeze"),
    (re.compile(r"\b(data loss|los(?:e|es|t) (?:data|session|state)|session(?:s)? (?:are )?lost)\b", re.I), 6, "data/session loss"),
    (re.compile(r"\b(wrong (?:terminal|pane|workspace|target)|route[sd]? to (?:the )?wrong)\b", re.I), 5, "wrong-target routing"),
    (re.compile(r"\b(cannot connect|can't connect|could not connect|connection fail|auth(?:entication)? fail)\b", re.I), 4, "connectivity/auth failure"),
    (re.compile(r"\b(unusable|unresponsive|stuck|wedged)\b", re.I), 3, "unusable/stuck"),
    (re.compile(r"\b(regression|regressed|previously worked|used to work)\b", re.I), 3, "regression wording"),
]

NIGHTLY_YES = re.compile(
    r"Can you reproduce this on cmux NIGHTLY\?.*?Yes, it still reproduces on NIGHTLY",
    re.I | re.S,
)
NIGHTLY_NO = re.compile(
    r"Can you reproduce this on cmux NIGHTLY\?.*?No, it does not reproduce on NIGHTLY",
    re.I | re.S,
)

@dataclass(frozen=True)
class SeverityRule:
    severity: str
    pattern: re.Pattern[str]
    reason: str
    # A rule that reads bodies picks up design discussion. "Arbitrary code
    # execution" in a paragraph weighing two designs is not a vulnerability
    # report, so the security rule only reads titles.
    title_only: bool = False


# Read in order: the first rule that matches sets severity. S1 and S2 describe
# what a user loses. S4 only applies when nothing worse matched.
SEVERITY_RULES: list[SeverityRule] = [
    SeverityRule(
        "S1: critical",
        re.compile(
            r"\b(arbitrary code execution|remote code execution|\brce\b|privilege escalation"
            r"|credentials? (?:leak|exposed|in plain ?text)|token (?:leak|exposed)"
            r"|secret(?:s)? (?:leak|exposed))\b",
            re.I,
        ),
        "a security exposure",
        title_only=True,
    ),
    SeverityRule(
        "S1: critical",
        re.compile(
            r"\b(data loss|lose[sd]? (?:all |my )?(?:work|data)"
            r"|(?:data|file|files|state|database|config|repo(?:sitory)?|index|settings) (?:is |are |get(?:s)? |was |were )?corrupt(?:s|ed|ion)?"
            r"|corrupt(?:s|ed|ing)? (?:the )?(?:data|file|files|state|database|config|repo(?:sitory)?|index|settings)"
            r"|crash(?:es|ed|ing)? on (?:launch|startup|open)|won'?t (?:launch|start)\b"
            r"|(?:cmux|the app) won'?t open"
            r"|(?:fails?|unable) to (?:launch|start|open) (?:cmux|the app)"
            r"|cannot (?:launch|start|open) (?:cmux|the app)|boot ?loop|kernel panic)\b",
            re.I,
        ),
        "data loss, or a build that will not start",
    ),
    SeverityRule(
        "S2: major",
        re.compile(
            r"\b(crash(?:es|ed|ing)?|panic(?:s|ked)?|deadlock|freeze[sd]?|frozen|hang(?:s|ing)?"
            r"|unusable|unresponsive|wedged"
            r"|lost? (?:session|state|scrollback|history)|session(?:s)? (?:are )?lost"
            r"|cannot connect|can'?t connect|could not connect|connection fail(?:s|ed|ure)?"
            r"|connection refused|refuse[sd]? connection"
            r"|auth(?:entication)? fail(?:s|ed|ure)?|fails? to (?:connect|authenticate|sign in)"
            r"|wrong (?:terminal|pane|workspace|target)|route[sd]? to (?:the )?wrong"
            r"|regression|regressed|previously worked|used to work|no longer works)\b",
            re.I,
        ),
        "a crash, hang, lost state, a broken connection, or a regression",
    ),
    SeverityRule(
        "S4: cosmetic",
        re.compile(
            r"\b(typo|misspell(?:ed|ing)?|capitali[sz]ation"
            r"|(?:label|button|menu|dialog|error message) wording"
            r"|mis-?align(?:ed|ment)|alignment|letter ?spacing|line ?spacing"
            r"|padding|margin|off-?by-?one pixel|pixel-?perfect"
            r"|truncat\w* (?:labels?|titles?|text|strings?|headers?)"
            r"|(?:labels?|titles?|text|headers?) (?:is |are |gets? |get )?truncat"
            r"|ellipsis|tooltip text|placeholder text"
            r"|icon (?:is )?(?:wrong|missing|blurry)|wrong (?:color|colour)"
            r"|cosmetic|visual (?:nit|polish)|nitpick)\b",
            re.I,
        ),
        "wording or appearance, with no effect on what cmux does",
    ),
]

SEVERITY_DEFAULT = ("S3: minor", "a bug with no crash, loss, or blocked path described")

# Areas. Each pattern is matched against the title (weight 3) and the first
# part of the body (weight 1). The winning area must be ahead of the runner-up,
# otherwise the issue keeps `needs-triage` and a person picks.
AREA_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("area: terminal", re.compile(r"\b(ghostty|terminal (?:surface|render|content|emulat)|scrollback|reflow|ansi|sgr|osc ?\d+|vt10\d|terminfo|cursor (?:shape|blink)|font (?:size|render|ligature)|glyph|sixel|kitty graphics|semantic zone|selection highlight|bracketed paste|shell integration|pty\b)\b", re.I)),
    ("area: input", re.compile(r"\b(keybind(?:ing)?|key ?binding|keyboard shortcut|hotkey|chord|ime\b|input method|korean|japanese|chinese|dead key|option key|meta key|modifier|mouse (?:click|wheel|scroll|report)|scroll ?wheel|trackpad|drag and drop|clipboard|copy ?/? ?paste|pasting|paste)\b", re.I)),
    ("area: layout", re.compile(r"\b(split(?:s|ting)?|pane(?:s)?|tab bar|tab(?:s)? (?:order|bar|strip)|window (?:size|position|management|resiz|mode|creation)|single window|surface(?:s)? (?:stuck|resiz|order|behind)|resiz(?:e|es|ing)|full ?screen|zoom(?:ed)? pane|layout|stage manager|multi-?monitor|display arrangement)\b", re.I)),
    ("area: sidebar", re.compile(r"\b(sidebar|side bar|left (?:panel|rail)|workspace list|group(?:s)? (?:collapse|expand)|reorder(?:able|ing)? (?:workspace|item)|needs input (?:status|badge))\b", re.I)),
    ("area: workspaces", re.compile(r"\b(workspace(?:s)?|session restore|restore(?:s|d)? (?:tabs|panes|session)|auto-?resume|resume after (?:relaunch|update|restart)|worktree|project(?:s)? (?:switch|list)|new workspace|fork(?:ing)? (?:a )?session|cwd\b|working director)\b", re.I)),
    ("area: agents", re.compile(r"\b(claude(?: code)?|codex|agent(?:s)?|acp\b|mcp\b|copilot|gemini|aider|hook(?:s)? (?:fire|error)|session-?end|agent chat|prompt (?:box|input)|teammate)\b", re.I)),
    ("area: cloud", re.compile(r"\b(cloud (?:machine|workspace|terminal|session|connection)|iroh|relay|vm\b|machines panel|cloud-?vm|remote machine provision)\b", re.I)),
    ("area: remote", re.compile(r"\b(ssh\b|remote (?:daemon|service|host|relay|session)|tunnel|pairing|pair (?:with|a) (?:device|iphone)|tailscale|port forward)\b", re.I)),
    ("area: ios", re.compile(r"\b(ios\b|iphone|ipad|testflight|app store|mobile (?:app|client)|push (?:alert|notification))\b", re.I)),
    ("area: cli", re.compile(r"\b(cmux (?:cli|ssh|tui|reload-config|tree|identify|list-)|\bcli\b|cmux-tui|socket (?:method|api|client)|sdk\b|json-?rpc|command line|subcommand)\b", re.I)),
    ("area: settings", re.compile(r"\b(settings?(?: (?:ui|pane|sheet|window|screen))?|preferences?|config(?:uration)? file|cmux\.json|defaults? (?:write|value)|toggle (?:in|under) settings|opt(?:-| )in setting)\b", re.I)),
    ("area: browser", re.compile(r"\b(browser|webview|web ?kit|vs ?code|inline editor|devtools|url bar|embedded (?:browser|page))\b", re.I)),
    ("area: command-palette", re.compile(r"\b(command palette|palette (?:search|input|overlay)|quick (?:open|switch)|fuzzy (?:search|find)|find (?:bar|in terminal))\b", re.I)),
    ("area: updates", re.compile(r"\b(sparkle|appcast|auto-?updat|update(?:s|d|r)? (?:to|from|check|fail)|nightly build|homebrew|brew (?:install|cask)|dmg\b|install(?:er|ation)|notariz|gatekeeper|code ?sign)\b", re.I)),
    ("area: auth", re.compile(r"\b(sign(?:-| )?in|sign(?:-| )?out|log(?:-| )?in|account|subscription|billing|license|stack auth|oauth|team(?:s)? (?:invite|member))\b", re.I)),
    ("area: performance", re.compile(r"\b(slow|latency|laggy|lag\b|cpu (?:usage|spin|burn)|burn(?:s|ing)? ~?\d*\s*cores?|memory (?:usage|leak|growth)|(?:memory|fd|file descriptor|handle) leak|leak(?:s|ing) memory|startup time|launch time|spin(?:ning)? (?:at|the) (?:runloop|idle)|idle (?:spin|wake)|battery|energy impact|throughput|benchmark|\bperf\b)\b", re.I)),
    ("area: localization", re.compile(r"\b(localiz|localis|translat|i18n|l10n|string catalog|xcstrings|right-to-left|\brtl\b)\b", re.I)),
    ("area: accessibility", re.compile(r"(\b(accessib|voiceover|screen reader|a11y|reduce motion|reduced transparency|dynamic type|keyboard(?:-| )only navigation|focus ring)\b|\bAX[A-Z]\w+)", re.I)),
    ("area: appearance", re.compile(r"\b(theme(?:s|d|ing)?|light mode|dark mode|color ?scheme|colour ?scheme|appearance|chrome (?:styling|quieter)|tint|accent color|transparen(?:cy|t)|blur|window chrome|title ?bar styling)\b", re.I)),
    ("area: notifications", re.compile(r"\b(notification(?:s)?|notify|banner|badge|bell\b|alert(?:s)?|toast|do not disturb|focus mode|needs input (?:bell|notification))\b", re.I)),
    ("area: docs", re.compile(r"\b(readme|documentation|docs? (?:page|site|link|typo)|changelog|contributing(?:\.md)?|landing page|website copy)\b", re.I)),
    ("area: build-and-ci", re.compile(r"\b(\bci\b|github actions?|workflow (?:file|run|fail)|runner(?:s)?|xcodebuild|swiftpm|spm\b|derived ?data|build (?:fail|break|graph|time)|test (?:lane|harness|flake|infra)|flaky test|merge queue|main (?:is |was )?(?:red|uncompilable|broken)|uncompilable|nightly (?:publish|failure|build)|linker|submodule)\b", re.I)),
]

BODY_WEIGHT_CHARS = 1200
TITLE_WEIGHT = 3
BODY_WEIGHT = 1

BUG_WORDS = re.compile(
    r"\b(bug|broken|break(?:s|ing)?|fail(?:s|ed|ing|ure)?|error(?:s)?|crash(?:es|ed|ing)?"
    r"|hang(?:s|ing)?|freeze[sd]?|frozen|wrong|incorrect|does ?n'?t work|not working"
    r"|no longer|regress(?:es|ed|ion)?|stuck|unable to|cannot|can'?t|never (?:fires|arrives|shows|appears)"
    r"|typo|misspell(?:ed|ing)?|ignored|silently|leaks?|misses|missing|off-?by-?one"
    r"|drops?|dropped|garbled|mojibake|duplicate(?:s|d)?|data loss)\b",
    re.I,
)

RFC_TITLE = re.compile(r"^\s*(\[rfc\]|rfc:)", re.I)
ENHANCEMENT_WORDS = re.compile(
    r"^\s*(feat(?:ure)?(?:\([^)]*\))?:|feature request:?|\[feature\]|support for|add support|please add)",
    re.I,
)


@dataclass
class Classification:
    """What the rules concluded, and which rule concluded it."""

    severity: str | None = None
    severity_reason: str = ""
    areas: list[str] = field(default_factory=list)
    area_scores: dict[str, int] = field(default_factory=dict)
    needs_triage: bool = False
    notes: list[str] = field(default_factory=list)

    def labels_to_add(self) -> list[str]:
        result = list(self.areas)
        if self.severity:
            result.append(self.severity)
        if self.needs_triage:
            result.append(NEEDS_TRIAGE)
        return result


def label_names(labels: Iterable[object]) -> set[str]:
    """Accept REST (`{"name": ...}`), GraphQL and plain-string label shapes."""
    names: set[str] = set()
    for label in labels or []:
        if isinstance(label, str):
            names.add(label)
        elif isinstance(label, dict) and label.get("name"):
            names.add(str(label["name"]))
    return names


def is_bug(title: str, body: str, labels: Iterable[object] = ()) -> bool:
    """Whether severity applies: severity describes something broken.

    A feature request has no severity. Saying an unbuilt feature is "S3" reads
    as a priority, which is a different argument and not one a rule can settle.
    """
    names = {name.lower() for name in label_names(labels)}
    if "bug" in names:
        return True
    if "enhancement" in names or "documentation" in names:
        return False
    if RFC_TITLE.search(title) or ENHANCEMENT_WORDS.search(title):
        return False
    text = f"{title}\n{body[:BODY_WEIGHT_CHARS]}"
    # If the severity rules can already see damage, the report is about damage.
    for rule in SEVERITY_RULES:
        if rule.severity != "S4: cosmetic" and rule.pattern.search(text):
            return True
    return bool(BUG_WORDS.search(text))


def severity_for(title: str, body: str) -> tuple[str, str]:
    """First matching rule wins, and the title gets read first.

    Two passes on purpose. "Cosmetic" is a claim about the whole report, so it
    needs title evidence; a body that happens to say "padding" in a
    reproduction step does not make a dropped-paste bug cosmetic. Severe
    signals count wherever they appear, because plenty of reports put the crash
    in the log paste rather than the title.
    """
    for rule in SEVERITY_RULES:
        if rule.pattern.search(title):
            return rule.severity, rule.reason
    head = body[:BODY_WEIGHT_CHARS]
    for rule in SEVERITY_RULES:
        if rule.title_only or rule.severity == "S4: cosmetic":
            continue
        if rule.pattern.search(head):
            return rule.severity, rule.reason
    return SEVERITY_DEFAULT


def score_areas(title: str, body: str) -> dict[str, int]:
    scores: dict[str, int] = {}
    head = body[:BODY_WEIGHT_CHARS]
    for area, pattern in AREA_RULES:
        score = 0
        if pattern.search(title):
            score += TITLE_WEIGHT
        if pattern.search(head):
            score += BODY_WEIGHT
        if score:
            scores[area] = score
    return scores


def pick_areas(scores: dict[str, int], *, limit: int = 2) -> list[str]:
    """Take the top area, plus a second only when it ties the top.

    A guess that is wrong costs more than no guess: a wrong `area:` label sends
    the issue to a person who then has to hand it back.
    """
    if not scores:
        return []
    ranked = sorted(scores.items(), key=lambda pair: (-pair[1], pair[0]))
    top_score = ranked[0][1]
    if top_score < TITLE_WEIGHT:
        # Body-only evidence. One passing mention of `ssh` is not an area.
        return []
    winners = [area for area, score in ranked if score == top_score]
    if len(winners) > limit:
        return []
    return winners


def classify(title: str, body: str, labels: Iterable[object] = ()) -> Classification:
    """Propose severity and area labels for one issue."""
    title = title or ""
    body = body or ""
    result = Classification()

    result.areas = pick_areas(score_areas(title, body))
    result.area_scores = score_areas(title, body)

    if is_bug(title, body, labels):
        severity, reason = severity_for(title, body)
        result.severity = severity
        result.severity_reason = reason
    else:
        result.notes.append("no severity: reads as a feature request or RFC, not something broken")

    if not result.areas:
        result.needs_triage = True
        result.notes.append("no area: the title did not match one area more than the others")

    if NIGHTLY_NO.search(body):
        result.notes.append("reporter says it does not reproduce on NIGHTLY")
    elif NIGHTLY_YES.search(body):
        result.notes.append("reporter says it still reproduces on NIGHTLY")

    return result


def existing_triage_labels(labels: Iterable[object]) -> set[str]:
    """Triage labels already on an issue, whoever put them there."""
    names = label_names(labels)
    return {
        name
        for name in names
        if name in SEVERITY_ORDER or name.startswith(AREA_PREFIX) or name == NEEDS_TRIAGE
    }

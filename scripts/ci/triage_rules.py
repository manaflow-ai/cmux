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
    # Severity normally stays off anything framed as an RFC or a request. A
    # security exposure named in a title is the exception: labelling an RFC
    # `S1` by mistake costs a relabel, and missing a real one costs more.
    beats_request_framing: bool = False


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
        beats_request_framing=True,
    ),
    SeverityRule(
        "S1: critical",
        re.compile(
            r"\b(data loss|lose[sd]? (?:all |my )?(?:work|data)"
            # Losing the windows you had open is losing work, whether or not
            # the report uses the words "data loss".
            r"|destroy(?:s|ed|ing)? (?:the |all |my )?(?:current )?(?:windows?|tabs?|panes?|splits?|session|workspace)"
            r"|lose[sd]? (?:all |my )?(?:open |current )?(?:windows?|tabs?|panes?|splits?)"
            r"|wipe[sd]? (?:the |all |my )?(?:windows?|tabs?|panes?|session|workspace)"
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
            r"|(?:lose[sd]?|lost) (?:session|state|scrollback|history)|session(?:s)? (?:are )?lost"
            r"|cannot connect|can'?t connect|could not connect|connection fail(?:s|ed|ure)?"
            r"|connection refused|refuse[sd]? connection"
            r"|auth(?:entication)? fail(?:s|ed|ure)?|fails? to (?:connect|authenticate|sign in)"
            r"|wrong (?:terminal|pane|workspace|window|target)|route[sd]? to (?:the )?wrong"
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
            r"|(?:labels?|titles?|text|headers?|names?) (?:is |are |gets? |get )?truncat\w*"
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

# Every area label the rules can produce, for validating what a form reports.
AREA_NAMES = frozenset(area for area, _pattern in AREA_RULES)

BODY_WEIGHT_CHARS = 1200
TITLE_WEIGHT = 3
BODY_WEIGHT = 1
# How far into a title to look for an area named as the subject.
SUBJECT_CHARS = 24

BUG_WORDS = re.compile(
    r"\b(bug|broken|break(?:s|ing)?|fail(?:s|ed|ing|ure)?|error(?:s)?|crash(?:es|ed|ing)?"
    r"|hang(?:s|ing)?|freeze[sd]?|frozen|wrong|incorrect|does ?n'?t work|not working"
    r"|no longer|regress(?:es|ed|ion)?|stuck|unable to|cannot|can'?t|never (?:fires|arrives|shows|appears)"
    r"|typo|misspell(?:ed|ing)?|ignored|silently|leaks?|misses|missing|off-?by-?one"
    r"|drops?|dropped|garbled|mojibake|corrupt(?:s|ed|ion)?|duplicate(?:s|d)?|data loss"
    # Slowness and visual breakage are defects too, and they are reported in
    # their own vocabulary rather than in the language of failure.
    r"|slow(?:ly|ness)?|sluggish|lag(?:s|gy|ging)?|latency|stutter(?:s|ing)?|jank(?:y)?"
    r"|flicker(?:s|ing)?|blurry|overlap(?:s|ping)?|clipped|cut off|off-?screen"
    r"|high cpu|cpu (?:usage|spike)|memory (?:usage|growth)|spins?|beachball"
    r"|shows? the old|out of date|stale"
    # "Does not allow" and "has no effect" are how most reports say "broken"
    # without using the word.
    r"|does ?n'?t (?:work|allow|open|apply|fire|respond|update|appear|show|save|persist)"
    r"|does not (?:work|allow|open|apply|fire|respond|update|appear|show|save|persist)"
    r"|is not (?:applied|respected|saved|persisted|honored|honoured)"
    r"|has no effect|never updates|ignores)\b",
    re.I,
)

RFC_TITLE = re.compile(r"^\s*(\[rfc\]|rfc:)", re.I)
ENHANCEMENT_WORDS = re.compile(
    r"^\s*(feat(?:ure)?(?:\([^)]*\))?:|feature request:?|\[feature\]|support for|add support|please add)",
    re.I,
)
# How a title reads when it asks for work rather than reporting damage. Only
# consulted when the evidence is weak: either the single matching rule was the
# cosmetic one, or nothing matched and the decision fell to `BUG_WORDS`. A
# damage rule outranks this, so a title can start with "Allow" and still
# report a crash.
REQUEST_TITLE = re.compile(
    r"^\s*(?:"
    r"(?:perf|chore|task|epic|spike|proposal|idea):"
    r"|(?:"
    r"add|allow|support|enable|expose|introduce|provide|option to|it would be"
    r"|make|use|switch to|prefer|adopt|move to|migrate"
    r"|remove|drop|deprecate|delete"
    r"|refactor|clean ?up|simplify|unify|consolidate|rename"
    r"|investigate|consider|revisit|audit|track|document|polish|explore"
    r"|do ?n'?t|do not|stop|avoid"
    r")\b"
    r")",
    re.I,
)
# cmux titles often lead with a scope, as in "iOS: decompose the surface view"
# or "perf: defer the probe". The words that matter come after it.
SCOPE_PREFIX = re.compile(r"^\s*[a-z0-9][a-z0-9 ._+/-]{0,24}:\s*", re.I)


FIX_PREFIX = re.compile(r"^\s*(fix|bug|bugfix|hotfix|regression|broken)\s*:", re.I)


def reads_as_a_request(title: str) -> bool:
    """Whether the title asks for work rather than reporting damage."""
    if FIX_PREFIX.search(title):
        # "fix: prefer the inherited working directory" says which side it is on.
        return False
    if REQUEST_TITLE.search(title):
        return True
    return bool(REQUEST_TITLE.search(SCOPE_PREFIX.sub("", title, count=1)))


@dataclass
class Classification:
    """What the rules concluded, and which rule concluded it."""

    severity: str | None = None
    severity_reason: str = ""
    areas: list[str] = field(default_factory=list)
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


def matched_rule(title: str, body: str) -> SeverityRule | None:
    """The first severity rule that matches, reading the title first.

    Two passes on purpose. "Cosmetic" is a claim about the whole report, so it
    needs title evidence; a body that happens to say "padding" in a
    reproduction step does not make a dropped-paste bug cosmetic. Severe
    signals count wherever they appear, because plenty of reports put the crash
    in the log paste rather than the title.
    """
    for rule in SEVERITY_RULES:
        if rule.pattern.search(title):
            return rule
    head = body[:BODY_WEIGHT_CHARS]
    for rule in SEVERITY_RULES:
        if rule.title_only or rule.severity == "S4: cosmetic":
            continue
        if rule.pattern.search(head):
            return rule
    return None


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
    rule = matched_rule(title, body)
    if rule is not None and rule.beats_request_framing:
        return True
    if RFC_TITLE.search(title) or ENHANCEMENT_WORDS.search(title):
        # A design document that discusses crashes is not a crash report.
        return False
    # A rule that names damage settles it, whatever else the title says.
    if rule is not None and rule.severity != "S4: cosmetic":
        return True
    if rule is not None:
        # Cosmetic wording, so this is a defect unless it asks for something new.
        return not reads_as_a_request(title)
    if reads_as_a_request(title):
        # No rule matched, so the only evidence left is a word somewhere in the
        # prose. "Refactor the sidebar store" says "wrong" in its third
        # paragraph and is still not a bug report.
        return False
    return bool(BUG_WORDS.search(f"{title}\n{body[:BODY_WEIGHT_CHARS]}"))


def severity_for(title: str, body: str) -> tuple[str, str]:
    """The severity for a report already known to describe something broken."""
    rule = matched_rule(title, body)
    if rule is not None:
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


# Words that name an area when they lead the title, used only by
# `declared_area`. Several scoring patterns want a qualifier on purpose
# (`cloud machine`, not every passing "cloud"), which a scope prefix like
# `Cloud:` never supplies. Deliberately left out: `nightly`, `release`, `build`
# and `install`, which name the channel or the feature an issue happens in far
# more often than they name its area ("NIGHTLY hangs: ...", "Install and
# Relaunch no longer relaunches").
DECLARED_WORDS: dict[str, tuple[str, ...]] = {
    "area: terminal": ("terminal", "ghostty", "scrollback", "escape sequence"),
    "area: input": ("input", "keyboard", "keybinding", "shortcut", "clipboard", "paste", "ime"),
    "area: cloud": ("cloud",),
    "area: remote": ("remote", "ssh"),
    "area: updates": ("updates", "installer", "homebrew", "sparkle"),
    "area: auth": ("auth", "login", "sign-in", "signin", "billing"),
    "area: performance": ("performance", "perf", "latency"),
    "area: localization": ("localization", "l10n", "i18n", "translation", "translations"),
    "area: accessibility": ("accessibility", "a11y", "voiceover"),
    "area: docs": ("docs", "documentation", "readme"),
    "area: build-and-ci": ("ci",),
}
DECLARED_RULES: list[tuple[str, re.Pattern[str]]] = [
    (area, re.compile(r"\b(?:" + "|".join(re.escape(w) for w in words) + r")\b", re.I))
    for area, words in DECLARED_WORDS.items()
]


# The issue forms ask this, and GitHub renders the answer as the next line.
FORM_AREA_HEADING = re.compile(r"^#+\s*Which part of cmux is this about\?\s*$", re.I | re.M)
# What GitHub writes for an optional field nobody filled in.
FORM_NO_ANSWER = {"", "not sure", "_no response_", "none"}


def form_area(body: str) -> str | None:
    """The area the reporter picked from the issue form's dropdown.

    This outranks every inference below it: the reporter chose from a list of
    the actual area labels, which is better evidence than any regex over their
    prose. It is also the only reason the dropdown is worth having, since body
    text alone never carries an area (see `pick_areas`).

    Returns None when the field is absent, skipped, or set to "Not sure", which
    is the common case: most issues do not come from the form at all.
    """
    heading = FORM_AREA_HEADING.search(body or "")
    if not heading:
        return None
    for line in body[heading.end() :].splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            # The next question already, so this one was left blank.
            return None
        # Options read `sidebar` or `remote (cmux ssh, tunnels)`. Take the label.
        answer = line.split("(")[0].strip().lower()
        if answer in FORM_NO_ANSWER:
            return None
        candidate = f"{AREA_PREFIX}{answer}"
        return candidate if candidate in AREA_NAMES else None
    return None


def declared_area(title: str, *, prefix_only: bool = False) -> str | None:
    """The area the title names up front, if it names exactly one.

    Two shapes count, and both are the reporter telling us the area rather than
    us inferring it from a word that happens to appear:

        Cloud: Codex TUI garbled after restoring a workspace
        Browser panes lose page state after being hidden

    The first is a scope prefix, an explicit declaration, and it wins outright.
    The second opens with the area as the subject of the sentence, which is
    weaker (the sentence has to start somewhere) so it only breaks a tie.
    `prefix_only` asks for the explicit shape alone.

    Either way, two areas in the opening means no declaration at all:
    `len(hits) == 1` is the whole safeguard, and a prefix like
    `Terminal paste:` names two areas, so it declares neither.
    """
    prefix = SCOPE_PREFIX.match(title)
    if prefix:
        scope = title[: prefix.end()]
        hits = {
            area
            for area, pattern in (*AREA_RULES, *DECLARED_RULES)
            if pattern.search(scope)
        }
        return hits.pop() if len(hits) == 1 else None
    if prefix_only:
        return None
    # No scope prefix, so the area has to be the first thing in the title.
    head = title.lstrip()[:SUBJECT_CHARS]
    hits = {
        area
        for area, pattern in (*AREA_RULES, *DECLARED_RULES)
        if (match := pattern.search(head)) and match.start() == 0
    }
    return hits.pop() if len(hits) == 1 else None


def pick_areas(
    scores: dict[str, int],
    *,
    limit: int = 2,
    title: str = "",
    reported: str | None = None,
) -> list[str]:
    """Take the top area, plus a second only when it ties the top.

    A guess that is wrong costs more than no guess: a wrong `area:` label sends
    the issue to a person who then has to hand it back. Two things outrank the
    guessing: an area the reporter picked on the issue form (`reported`), and a
    title that declares its own area.
    """
    if reported:
        # The reporter picked this off a list of the real labels. Done.
        return [reported]
    explicit = declared_area(title, prefix_only=True)
    if explicit:
        return [explicit]
    ranked = sorted(scores.items(), key=lambda pair: (-pair[1], pair[0]))
    top_score = ranked[0][1] if ranked else 0
    if top_score < TITLE_WEIGHT:
        # No area in the title. Body-only evidence does not carry an area (one
        # passing mention of `ssh` in a paragraph is not the subject), but the
        # area the title leads with does. This is what keeps a title like
        # `Cloud team picker ...` off `needs-triage`, where the scoring pattern
        # wants `cloud machine` and the title never says it.
        declared = declared_area(title)
        return [declared] if declared else []
    winners = [area for area, score in ranked if score == top_score]
    if len(winners) > limit:
        # The title genuinely names several areas, so a person picks. Leading
        # with one of them is not a declaration here: `Sidebar, splits, ssh and
        # the iOS app all need a rethink` is an enumeration.
        return []
    return winners


def classify(title: str, body: str, labels: Iterable[object] = ()) -> Classification:
    """Propose severity and area labels for one issue."""
    title = title or ""
    body = body or ""
    result = Classification()

    reported = form_area(body)
    result.areas = pick_areas(score_areas(title, body), title=title, reported=reported)
    if reported:
        result.notes.append(f"area from the issue form: the reporter picked {reported}")

    if is_bug(title, body, labels):
        severity, reason = severity_for(title, body)
        result.severity = severity
        result.severity_reason = reason
    else:
        result.notes.append("no severity: reads as a feature request or RFC, not something broken")

    if not result.areas:
        result.needs_triage = True
        result.notes.append("no area: the title did not match one area more than the others")

    return result


def existing_triage_labels(labels: Iterable[object]) -> set[str]:
    """Triage labels already on an issue, whoever put them there.

    Matched case-insensitively: GitHub label names are case-insensitively
    unique, so `S2: Major` typed by hand is the same label as `S2: major` and
    means the same thing, that a human got here first.
    """
    severities = {name.lower() for name in SEVERITY_ORDER}
    return {
        name
        for name in label_names(labels)
        if name.lower() in severities
        or name.lower().startswith(AREA_PREFIX)
        or name.lower() == NEEDS_TRIAGE
    }

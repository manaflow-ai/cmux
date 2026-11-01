import { sessionInfoGridScenes } from "./sessionInfoGridScenes";
import type { GridLine, GridMetric, GridPoint, GridScene } from "./gridLines";

// Roles identify ink targets; selectors remain available while surfaces migrate.
const selectorRoles: Record<string, string> = {
  ":scope": "box",
  ".acpmux-composer-box": "box",
  ".acpmux-composer-plus .acpmux-picker-button svg": "plus",
  ".acpmux-mic svg": "mic",
  ".acpmux-send:not(.acpmux-steer-now) svg": "send",
  ".acpmux-mode-text": "first-chip-text",
  ".acpmux-context-ring svg": "ring",
  ".ui-menu-check": "state",
  ".acpmux-project-check": "state",
  '[aria-checked="true"] svg': "state",
  ".ui-menu-icon": "icon",
  ".acpmux-menu-item > svg": "icon",
  ".acpmux-menu-hint": "shortcut",
  '[role="option"] .acpmux-icon': "icon",
  ".ui-menu-shortcut, .ui-submenu-chevron": "shortcut",
  ".cv-tool__icon": "icon",
  ".cv-iconbtn svg": "icon",
  ".acpmux-lineage__icon": "lead",
  ".acpmux-running-tray__head .acpmux-lineage__icon": "lead",
  ".acpmux-location-leading svg": "lead",
  ".acpmux-location-picker:last-child svg": "trail",
  ".acpmux-access-trigger svg": "lead",
  ".acpmux-trust-ask-icon": "lead",
  ".acpmux-queued-kind": "lead",
  ".acpmux-permission-request-icon": "icon",
  ".acpmux-permission-card-leading": "icon",
  ".acpmux-session-info-section__icon": "icon",
  ".cv-tool__chevron": "chevron",
  ".acpmux-running-tray__finished svg": "chevron",
  ".acpmux-running-tray__status": "chevron",
};
const point = (selector: string, metric: GridMetric, role?: string): GridPoint => ({
  selector,
  metric,
  role: selectorRoles[selector] ?? role ?? (metric === "text" || metric === "optical" ? "text" : undefined),
  ...(selector === ".acpmux-composer-box" ? { scope: "document" as const } : {}),
});
const token = (name: string) => `var(--grid-${name})`;
const value = (name: string, selector: string, metric: GridMetric, expected: string | GridPoint): GridLine => ({
  name,
  actual: point(selector, metric),
  expected,
});
const from = (name: string, selector: string, metric: GridMetric, origin: GridPoint, expected: string): GridLine => ({
  ...value(name, selector, metric, expected),
  origin,
});
const left = (name: string, selector: string, metric: GridMetric, expected: string) =>
  from(name, selector, metric, point(":scope", "left"), expected);
const trail = (selector: string, expected: string, metric: GridMetric = "cx") =>
  from("trail", ":scope", "right", point(selector, metric), expected);
const mid = (selector: string, anchor: string): GridLine =>
  value("mid: optical text", selector, "optical", point(anchor, "cy"));
const centered = (glyph: string, control: string): GridLine[] => [
  value("mid: glyph", glyph, "cy", point(control, "cy")),
  value("control: glyph x", glyph, "cx", point(control, "cx")),
];
const scene = (surface: string, entry: string, variant: string, root: string, lines: GridLine[]): GridScene => ({
  surface,
  level: surface.startsWith("composer.") ? "fail" : "warn",
  entry,
  variant,
  root,
  rootRole: ["composer.box", "composer.foot", "stack.strip", "stack.trust"].includes(surface) ? surface : undefined,
  lines,
});
const plus = ".acpmux-composer-plus .acpmux-picker-button";

const placeholder = ".acpmux-md-placeholder";
const composer = (variant: string, text = placeholder, entry = "agent-pane.composer-row") => {
  // Claude's look keeps the mic last in every state (#29796): Send, Stop or steer stands one control
  // in from it, so the box's trailing line is the mic's.
  const last = ".acpmux-mic";
  return scene("composer.box", entry, variant, ".acpmux-composer-box", [
    left("edge: control inset", plus, "left", token("composer-inset")),
    left("lead", `${plus} svg`, "cx", token("composer-lead-center")),
    left("text", text, "text", token("composer-text")),
    trail(`${last} svg`, token("composer-trail-center")),
    value("control size", plus, "width", token("composer-control")),
    value("radius", ":scope", "radius", token("composer-radius")),
    ...(variant === "attach-screenshot" ? [] : [value("box height", ":scope", "height", token("composer-box"))]),
    mid(text, plus),
    ...centered(`${plus} svg`, plus),
    ...centered(`${last} svg`, last),
    value("mid: trailing control", last, "cy", point(plus, "cy")),
  ]);
};
// A two-line draft grows the box, and + and Send stay on its last line, so the one-line box's
// height and first-line optical center do not apply; its text column is still the 44 px line.
const draftLines = scene("composer.box", "agent-pane.composer-row", "grid-draft-lines", ".acpmux-composer-box", [
  left("edge: control inset", plus, "left", token("composer-inset")),
  left("lead", `${plus} svg`, "cx", token("composer-lead-center")),
  left("text", ".acpmux-md p", "text", token("composer-text")),
  trail(".acpmux-mic svg", token("composer-trail-center")),
  value("radius", ":scope", "radius", token("composer-radius")),
  ...centered(`${plus} svg`, plus),
  value("mid: trailing control", ".acpmux-mic", "cy", point(plus, "cy")),
]);
const running = composer("grid-running");
running.textIncludes = { selector: placeholder, text: "↵ steer · ⌘↵ queue" };
// The capture fixture's prompt shows no placeholder (MarkdownField hides it whenever the field holds
// markdown), so its text lines are a design absence; the empty prompt's text line is measured in
// composer.box/claude-auto and grid-running. The box's controls and radius are still measured here.
const attachScreenshot = composer("attach-screenshot", placeholder, "agent-pane.composer");
attachScreenshot.absent = {
  [placeholder]: "The capture fixture's prompt shows no placeholder; claude-auto measures the text line.",
};
// A fail-level scene counts an unmeasured line as off, so the absent text lines are not listed here.
attachScreenshot.lines = attachScreenshot.lines.filter((line) => line.actual.selector !== placeholder);

const stackToken: Record<string, string> = {
  "stack.strip": "strip",
  "stack.trust": "trust-bar",
  "stack.subagents": "tray",
  "stack.tray": "tray",
  "stack.queued": "queue",
};
const stack = (
  surface: string,
  entry: string,
  variant: string,
  root: string,
  lead: string,
  text: string,
  end: string,
) =>
  scene(surface, entry, variant, root, [
    left(
      "edge: control inset",
      lead,
      "left",
      `calc(${token(`${stackToken[surface]}-lead-center`)} - ${token("icon-box")} / 2)`,
    ),
    left("lead", lead, "cx", token(`${stackToken[surface]}-lead-center`)),
    left("text", text, "text", token(`${stackToken[surface]}-text`)),
    trail(end, token(`${stackToken[surface]}-trail-center`)),
    value("row height", ":scope", "height", token("row")),
    mid(text, lead),
    value("mid: trail", end, "cy", point(lead, "cy")),
  ]);
const menuToken = (name: string) => `var(--cmux-menu-${name})`;
const menu = (surface: string, entry: string, variant: string, root: string, state: boolean) =>
  scene(surface, entry, variant, root, [
    left("edge: highlight", ".ui-menu-item", "left", menuToken("highlight-inset")),
    value("radius", ":scope", "radius", menuToken("highlight-radius")),
    left("text", ".ui-menu-item", "text", menuToken(state ? "state-text-x" : "text-x")),
    // A state-only menu has no leading icon; its leading mark is the state column itself.
    {
      ...left(
        "lead/state",
        state ? ".ui-menu-check" : ".ui-menu-icon",
        state ? "cx" : "left",
        menuToken(state ? "state-x" : "icon-x"),
      ),
      all: true,
    },
    trail(".ui-menu-shortcut, .ui-submenu-chevron", menuToken("trailing"), "right"),
    mid(".ui-menu-item", ".ui-menu-item"),
  ]);
const card = (
  surface: string,
  entry: string,
  variant: string,
  root: string,
  icon: string,
  title: string,
  body: string,
  end: string,
) =>
  scene(surface, entry, variant, root, [
    value("edge: padding", ":scope", "padding", token("cards-padding")),
    left("lead", icon, "left", token("cards-lead")),
    left("text: heading", title, "text", token("cards-text")),
    left("text: body", body, "text", token("cards-text")),
    trail(end, token("cards-trail-center")),
    value("radius", ":scope", "radius", token("cards-radius")),
    mid(title, icon),
  ]);

const changesInset = `calc(3 * ${token("base")})`;
const changesPanel = (): GridScene[] =>
  [
    scene("changes.panel", "agent-pane.diff-panel", "loaded-scope", ".acpmux-branch-row", [
      value("control: branch pill", ".acpmux-branch-pill", "height", token("row")),
      value("control: create PR", ".acpmux-pull-request-create", "height", token("row")),
      value("button padding: create PR", ".acpmux-pull-request-create", "padding", changesInset),
      from("branch arrow gap", ".acpmux-branch-arrow", "left", point(".acpmux-branch-from", "right"), token("gap")),
    ]),
    scene("changes.panel", "agent-pane.diff-panel", "tracked-only", ".acpmux-changes-banner", [
      value("edge: padding", ":scope", "padding", changesInset),
      from("edge: top", ".acpmux-changes-banner-text", "top", point(":scope", "top"), changesInset),
      value("control: copy cleanup", ".acpmux-changes-banner-action", "height", token("pill")),
      value("button padding: copy cleanup", ".acpmux-changes-banner-action", "padding", token("gap")),
      value("button padding: refresh", ".acpmux-changes-banner-refresh", "padding", token("gap")),
    ]),
    scene("changes.panel", "agent-pane.diff-panel", "open-file-error", ".acpmux-diff-notice", [
      value("edge: padding", ":scope", "padding", changesInset),
      left("text", ".acpmux-diff-notice-text", "text", changesInset),
      from("edge: top", ".acpmux-git-secondary", "top", point(":scope", "top"), token("gap")),
      value("control: dismiss", ".acpmux-git-secondary", "height", token("pill")),
      value("button padding: dismiss", ".acpmux-git-secondary", "padding", token("gap")),
      trail(".acpmux-git-secondary", changesInset, "right"),
    ]),
    scene("changes.panel", "agent-pane.diff-panel", "stage-hunk", ".acpmux-hunk-actions", [
      value("edge: padding", ":scope", "padding", changesInset),
      value("control: stage hunk", ".acpmux-hunk-stage", "height", token("pill")),
      value("button padding: stage hunk", ".acpmux-hunk-stage", "padding", token("gap")),
      trail(".acpmux-hunk-stage", changesInset, "right"),
    ]),
    ...["toolbar", "stage-hunk"].map((variant) =>
      scene("changes.panel", "agent-pane.diff-panel", variant, ".acpmux-diff-keys", [
        value("edge: padding", ":scope", "padding", changesInset),
        left("text", ".acpmux-diff-key", "left", changesInset),
        from("edge: bottom", ":scope", "bottom", point(".acpmux-diff-key", "bottom"), token("base")),
      ]),
    ),
    scene("changes.panel", "agent-pane.diff-panel", "review-file", ".acpmux-revert-bar", [
      value("edge: padding", ":scope", "padding", changesInset),
      left("text", ".acpmux-revert-count", "text", changesInset),
      value("control: field", ".acpmux-revert-bar input", "height", token("row")),
      value("field padding", ".acpmux-revert-bar input", "padding", changesInset),
      value("control: send", ".acpmux-revert-send", "height", token("row")),
      value("button padding: send", ".acpmux-revert-send", "padding", changesInset),
      trail(".acpmux-revert-send", changesInset, "right"),
    ]),
    scene("changes.panel", "agent-pane.diff-panel", "review-file", ".acpmux-hunk-actions[data-decision]", [
      value("control: undo", ".acpmux-hunk-undo", "height", token("pill")),
      value("button padding: undo", ".acpmux-hunk-undo", "padding", token("gap")),
      trail(".acpmux-hunk-undo", changesInset, "right"),
    ]),
    scene("changes.panel", "agent-pane.diff-panel", "review-file", ".acpmux-hunk-actions:not([data-decision])", [
      value("control: accept", ".acpmux-hunk-accept", "height", token("pill")),
      value("button padding: reject", ".acpmux-hunk-reject", "padding", token("gap")),
      value("button padding: accept", ".acpmux-hunk-accept", "padding", token("gap")),
      trail(".acpmux-hunk-accept", changesInset, "right"),
    ]),
    scene("changes.panel", "agent-pane.diff-panel", "review-threads", ".acpmux-review-thread", [
      value("edge: padding", ":scope", "padding", token("gap")),
    ]),
    scene("changes.panel", "agent-pane.diff-panel", "address-thread", ".acpmux-review-actions", [
      value("control: address", ".acpmux-review-address", "height", token("pill")),
      value("button padding: address", ".acpmux-review-address", "padding", token("gap")),
    ]),
  ].map((item) => ({ ...item, level: "fail" as const }));
// A 28 control (grid.md section 4) and the harness rows' text: lead 8 + the 20 box + 8.
const control28 = `calc(${token("base")} * 7)`;
const harnessText = `calc(${token("gap")} + ${token("icon-box-comfortable")} + ${token("gap")})`;
const noticeCard = ".acpmux-host-error-card";

/** Promotion is per surface and requires a fleet measurement; no surface is assumed to pass. */
export const gridScenes: GridScene[] = [
  ...sessionInfoGridScenes,
  composer("claude-auto"),
  running,
  composer("grid-draft", ".acpmux-md p"),
  draftLines,
  attachScreenshot,
  scene("composer.foot", "agent-pane.composer-row", "claude-auto", ".acpmux-composer-foot", [
    from("edge: gap", ":scope", "top", point(".acpmux-composer-box", "bottom"), token("gap-foot")),
    value("row height", ":scope", "height", token("composer-quiet-row-height")),
    from(
      "lead",
      ".acpmux-access-trigger svg",
      "cx",
      point(".acpmux-composer-box", "left"),
      token("composer-lead-center"),
    ),
    from(
      "trail",
      ".acpmux-composer-box",
      "right",
      point(".acpmux-context-ring svg", "cx"),
      token("composer-trail-center"),
    ),
    value("mid: mode mark", ".acpmux-access-trigger svg", "cy", point(":scope", "cy")),
    mid(".acpmux-model-detail:not(.acpmux-fit-label)", ":scope"),
    value("mid: ring", ".acpmux-context-ring svg", "cy", point(":scope", "cy")),
  ]),
  scene("composer.foot", "agent-pane.composer-row", "grid-running", ".acpmux-composer-foot", [
    from("edge: gap", ":scope", "top", point(".acpmux-composer-box", "bottom"), token("gap-foot")),
    value("row height", ":scope", "height", token("composer-quiet-row-height")),
    from(
      "lead",
      ".acpmux-access-trigger svg",
      "cx",
      point(".acpmux-composer-box", "left"),
      token("composer-lead-center"),
    ),
    from(
      "trail",
      ".acpmux-composer-box",
      "right",
      point(".acpmux-context-ring svg", "cx"),
      token("composer-trail-center"),
    ),
    value("mid: mode mark", ".acpmux-access-trigger svg", "cy", point(":scope", "cy")),
    mid(".acpmux-model-detail:not(.acpmux-fit-label)", ":scope"),
    value("mid: ring", ".acpmux-context-ring svg", "cy", point(":scope", "cy")),
  ]),
  stack(
    "stack.strip",
    "agent-pane.composer-strip",
    "project",
    ".acpmux-composer-strip",
    ".acpmux-location-leading svg",
    ".acpmux-location-label",
    ".acpmux-location-picker:last-child svg",
  ),
  stack(
    "stack.trust",
    "agent-pane.trust-ask",
    "grid-ask",
    ".acpmux-trust-ask",
    ".acpmux-trust-ask-icon",
    ".acpmux-trust-ask-text",
    ".acpmux-trust-ask-action:last-child",
  ),
  stack(
    "stack.subagents",
    "agent-pane.subagent-tray",
    "one-running",
    ".acpmux-agent-line",
    ".acpmux-lineage__icon",
    ".acpmux-summary-agent__name",
    ".acpmux-agent-line__stop-slot",
  ),
  ...["several-running", "grid-31"].map((variant) =>
    stack(
      "stack.subagents",
      "agent-pane.subagent-tray",
      variant,
      ".acpmux-agent-line",
      ".acpmux-lineage__icon",
      ".acpmux-summary-agent__name",
      ".acpmux-agent-line__stop-slot",
    ),
  ),
  ...["many-folded", "grid-31"].map((variant) =>
    stack(
      "stack.tray",
      "agent-pane.subagent-tray",
      variant,
      ".acpmux-running-tray__head",
      ".acpmux-lineage__icon",
      ".acpmux-running-tray__title",
      ".acpmux-running-tray__status",
    ),
  ),
  scene("stack.subagents", "agent-pane.subagent-tray", "grid-31", ".acpmux-running-tray", [
    left("header: lead", ".acpmux-running-tray__head .acpmux-lineage__icon", "cx", token("tray-lead-center")),
    left("header: text", ".acpmux-running-tray__title", "text", token("tray-text")),
    mid(".acpmux-running-tray__title", ".acpmux-running-tray__head .acpmux-lineage__icon"),
    left("footer: text", ".acpmux-running-tray__finished .acpmux-summary-text", "text", token("tray-text")),
    trail(".acpmux-running-tray__finished svg", token("tray-trail-center")),
    mid(".acpmux-running-tray__finished .acpmux-summary-text", ".acpmux-running-tray__finished svg"),
  ]),
  stack(
    "stack.queued",
    "agent-pane.composer-row",
    "queued",
    ".acpmux-queued",
    ".acpmux-queued-kind",
    ".acpmux-queued-text",
    ".acpmux-queued-actions button:last-child",
  ),
  menu("menu.context", "ui.context-menu", "open", ".ui-context-menu", false),
  menu("menu.mode", "agent-pane.composer-pickers", "permission-menu", ".acpmux-access-menu", true),
  menu("menu.mode", "ui.menu", "open", ".menu-gallery-popup", true),
  scene("menu.plus", "agent-pane.composer", "add-menu", ".acpmux-composer-plus .acpmux-menu", [
    left("edge: highlight", ".acpmux-menu-item", "left", menuToken("highlight-inset")),
    left("lead", ".acpmux-menu-item > svg", "left", menuToken("icon-x")),
    left("text", ".acpmux-menu-label", "text", menuToken("text-x")),
    trail(".acpmux-menu-hint", menuToken("trailing"), "right"),
    mid(".acpmux-menu-label", ".acpmux-menu-item > svg"),
  ]),
  scene("menu.project", "agent-pane.project-chooser", "open-current", ".acpmux-project-menu", [
    left("edge: highlight", '[role="option"]', "left", menuToken("highlight-inset")),
    left("lead", '[role="option"] .acpmux-icon', "left", menuToken("state-icon-x")),
    left("text", ".acpmux-menu-label", "text", menuToken("state-text-x")),
    { ...left("state", ".acpmux-project-check", "cx", menuToken("state-x")), all: true },
    trail(".acpmux-project-check", menuToken("trailing")),
    mid(".acpmux-menu-label", '[role="option"] .acpmux-icon'),
  ]),
  menu("picker.model", "agent-pane.composer-pickers", "model-menu", ".acpmux-quick-menu", true),
  menu("picker.account", "agent-pane.composer-pickers", "claude-direct-accounts", ".acpmux-quick-submenu", true),
  // #27948 moved the levels from an inline fieldset into the running model's side dropdown.
  scene("picker.effort", "agent-pane.composer-pickers", "effort-menu", ".acpmux-quick-effort-menu", [
    left("edge", ".acpmux-quick-effort-segment", "left", menuToken("highlight-inset")),
    left("lead: checked state", '[aria-checked="true"] svg', "cx", menuToken("state-x")),
    left("text", ".acpmux-quick-effort-segment", "text", menuToken("state-text-x")),
    trail(".acpmux-quick-effort-segment:last-child", menuToken("trailing")),
    mid(".acpmux-quick-effort-segment", ".acpmux-quick-effort-segment"),
  ]),
  scene("transcript.toolgroup", "agent-pane.tool-row-column", "column", ".cv-tool", [
    left(
      "edge/lead",
      ".cv-tool__icon",
      "left",
      `calc(${token("transcript-icon-box")} - ${token("transcript-icon-box")})`,
    ),
    value("icon box", ".cv-tool__icon", "width", token("transcript-icon-box")),
    left("text", ".cv-tool__text, .cv-command__text", "text", token("transcript-text-gap")),
    trail(".cv-tool__chevron", `calc(${token("transcript-icon-box")} - ${token("transcript-icon-box")})`, "right"),
    mid(".cv-tool__text, .cv-command__text", ".cv-tool__icon"),
  ]),
  // The turn footer's action row (TurnRows.tsx TurnFooter): Copy, Pin, Read aloud and More, then its
  // time. A reply no longer draws its own row (#29740: model.ts hasReplyActions is false, and the
  // agent-pane.reply-actions gallery entry is gone), so the footer under the first turn, which the
  // `footer` variant points at, is the one action row the transcript draws.
  scene(
    "transcript.actions",
    "agent-pane.transcript-row-alignment",
    "footer",
    ".acpmux-turnSummary .cv-turn-actions:not(.cv-turn-actions--empty)",
    [
      trail(".cv-turn-time", token("transcript-action-trail-center")),
      value("action control", ".cv-iconbtn", "width", token("transcript-action-control")),
      ...centered(".cv-iconbtn svg", ".cv-iconbtn"),
      mid(".cv-turn-time", ".cv-iconbtn"),
    ],
  ),
  card(
    "transcript.cards",
    "agent-pane.permission-card",
    "grid-pending",
    ".acpmux-permission-card",
    ".acpmux-permission-request-icon",
    ".acpmux-permission-request-label",
    ".acpmux-permission-scope",
    ".acpmux-permission-buttons button:last-child",
  ),
  card(
    "transcript.cards",
    "agent-pane.question-card",
    "pending-single",
    ".acpmux-question",
    ".acpmux-permission-card-leading",
    ".acpmux-question-prompt",
    ".acpmux-question-row",
    ".acpmux-question-submit",
  ),
  card(
    "transcript.cards",
    "agent-pane.summary-card",
    "finished-open",
    ".acpmux-summary-card",
    ".acpmux-summary-card__fold--icon",
    ".acpmux-summary-card__title",
    ".acpmux-summary-text",
    ".acpmux-summary-card__close",
  ),
  // The Changes panel (DiffPanel.tsx): its bars (notice, hunk actions, revert, keys) inset their
  // content 12 from the panel edge, every control in them is 24 or 28 tall, and a button's side
  // padding is 8 (24 tall) or 12 (28 tall).
  ...changesPanel(),
  // The failed turn's card (TurnRows.tsx TurnFailure, default `card` arm): Lawrence via Leo,
  // 2026-10-28, "needs more left padding". Its icon box sits on the card's lead and the cause and
  // its buttons on the card's text column; there is no trailing control.
  {
    ...scene("transcript.cards", "agent-pane.turn-error-card", "rate-limited", ".cv-turn-error--card", [
      value("edge: padding", ":scope", "padding", token("cards-padding")),
      from("edge: top", ".cv-turn-error__cause", "top", point(":scope", "top"), token("cards-padding")),
      left("lead", ".cv-turn-error__icon", "left", token("cards-lead")),
      value("icon box", ".cv-turn-error__icon", "width", token("icon-box")),
      left("text: heading", ".cv-turn-error__cause", "text", token("cards-text")),
      left("text: actions", ".cv-turn-error__actions > :first-child", "left", token("cards-text")),
      value("radius", ":scope", "radius", token("cards-radius")),
      mid(".cv-turn-error__cause", ".cv-turn-error__icon"),
    ]),
    level: "fail",
  },
  // Session status (HarnessStatusCard.tsx): Lawrence via Leo, 2026-10-28, "copy all alignment
  // with 'X'". The header actions centre on the header's first line (the harness eyebrow), and
  // the close control is the card's 28 trailing control ending 12 in.
  {
    ...scene("transcript.cards", "agent-pane.harness-status", "claude", ".acpmux-harness-status", [
      value("edge: padding", ":scope", "padding", token("cards-padding")),
      value("radius", ":scope", "radius", token("cards-radius")),
      value("close control", ".acpmux-harness-status__close", "width", token("cards-control")),
      trail(".acpmux-harness-status__close", token("cards-trail-center")),
      ...centered(".acpmux-harness-status__close svg", ".acpmux-harness-status__close"),
      value(
        "mid: close on first line",
        ".acpmux-harness-status__close",
        "cy",
        point(".acpmux-harness-status__eyebrow", "optical"),
      ),
      mid(".acpmux-harness-status__copy-all", ".acpmux-harness-status__close"),
    ]),
    level: "fail",
  },
  // The notice and error card over the composer (`.acpmux-host-error-card`: HostError.tsx's
  // folder harness card, HarnessHealthNotice.tsx, RulesNotice.tsx). It is a card (grid.md 5.6):
  // padding 12, radius 12, its action row 8 under the text with an 8 gap between buttons. It has
  // no header icon and no trailing control, so it has no lead, text column or trail line.
  ...[
    ["agent-pane.host-error", "enable", noticeCard],
    ["agent-pane.harness-health-notice", "signed-out", `.acpmux-harness-notice ${noticeCard}`],
  ].map(([entry, variant, root]) => ({
    ...scene("cards.notice", entry!, variant!, root!, [
      value("edge: padding", ":scope", "padding", token("cards-padding")),
      value("edge: padding top", ":scope", "padding-top", token("cards-padding")),
      value("edge: padding bottom", ":scope", "padding-bottom", token("cards-padding")),
      from(
        "action row",
        ".acpmux-host-error-actions > button:first-child",
        "top",
        point(":scope > p:last-of-type", "bottom"),
        token("gap"),
      ),
      ...(variant === "signed-out"
        ? [
            from(
              "actions: gap",
              ".acpmux-host-error-actions > button:nth-child(2)",
              "left",
              point(".acpmux-host-error-actions > button:first-child", "right"),
              token("gap"),
            ),
          ]
        : []),
      value("radius", ":scope", "radius", token("cards-radius")),
    ]),
    level: "fail" as const,
  })),
  {
    ...scene("cards.notice", "agent-pane.rules-notice", "collapsed", `.acpmux-rules-notice ${noticeCard}`, [
      value("edge: padding", ":scope", "padding", token("cards-padding")),
      value("edge: padding top", ":scope", "padding-top", token("cards-padding")),
      value("edge: padding bottom", ":scope", "padding-bottom", token("cards-padding")),
      value("radius", ":scope", "radius", token("cards-radius")),
    ]),
    level: "fail",
  },
  // Session Info is measured above as one row surface, not as independent padded cards.
  // Settings-style lists in a pane (grid.md 5.7): the Harnesses page (HarnessesScreen.tsx). Its rows
  // are section 3 rows with the row box as the highlight: the mark's 20 box 8 in, the name and
  // status 8 after it, the trailing action ending 8 in. The page's 28 controls and its side inset
  // sit on the 4 grid (16 minimum).
  ...[
    ["this-mac", "claude"],
    // this-mac's play signs Codex in, which takes its action away: its Codex row is measured in
    // hover, the variant with no play.
    ["hover", "codex"],
  ].map(([variant, harness]): GridScene => ({
    ...scene("pane.lists", "agent-pane.harnesses", variant!, `.acpmux-harness-row[data-harness-row="${harness}"]`, [
      left("lead", ".agent-mark", "left", token("gap")),
      value("icon box", ".agent-mark", "width", token("icon-box-comfortable")),
      left("text: name", ".acpmux-harness-name", "text", harnessText),
      left("text: detail", ".acpmux-harness-detail", "text", harnessText),
      trail(".acpmux-harness-action", token("gap"), "right"),
      value("action control", ".acpmux-harness-action", "height", control28),
      value("mid: icon", ".agent-mark", "cy", point(":scope", "cy")),
      value("mid: action", ".acpmux-harness-action", "cy", point(":scope", "cy")),
    ]),
    level: "fail",
  })),
  {
    ...scene("pane.lists", "agent-pane.harnesses", "this-mac", ".acpmux-harnesses", [
      value(
        "edge: side inset",
        ":scope",
        "padding",
        // The page centres a 560 column in the pane (the gallery's pane is the viewport); the inset
        // rounds down to the 4 grid, 16 at least.
        `max(calc(${token("base")} * 4), round(down, calc((100vw - 560px) / 2), ${token("base")}))`,
      ),
      value("close control", ".acpmux-harnesses-close", "height", control28),
      value("close control: width", ".acpmux-harnesses-close", "width", control28),
      value("close radius", ".acpmux-harnesses-close", "radius", `calc(${token("base")} * 1.5)`),
      ...centered(".acpmux-harnesses-close svg", ".acpmux-harnesses-close"),
      // Custom harness… is a row of the same list (#28906): its text on the rows' text column, its
      // end 8 in like theirs.
      from(
        "custom: text",
        ".acpmux-harnesses-custom .acpmux-harness-name",
        "text",
        point(".acpmux-harnesses-custom", "left"),
        harnessText,
      ),
      from(
        "custom: end",
        ".acpmux-harnesses-custom",
        "right",
        point(".acpmux-harnesses-custom .acpmux-harness-detail", "right"),
        token("gap"),
      ),
    ]),
    level: "fail",
  },
];

// These are omissions in the current component design, not selector fallbacks. All other
// missing selectors fail fixture coverage so renames cannot produce a green warning run.
const absentBySurface: Record<string, Record<string, string>> = {
  "stack.trust": {
    ".acpmux-trust-ask-icon": "TrustAsk renders text and buttons without a leading mark.",
  },
  "stack.queued": {
    ".acpmux-queued-kind": "Ordinary queued prompts have no leading mark; only steering entries render kind.",
  },
  "menu.context": {
    ".ui-menu-icon": "The context-menu open fixture has text-only actions.",
    ".ui-menu-shortcut, .ui-submenu-chevron": "These context actions have neither shortcut nor submenu.",
  },
  "picker.account": {
    ".ui-menu-shortcut, .ui-submenu-chevron":
      "AccountRows renders account labels and selection marks without shortcuts or submenus.",
  },
  "picker.effort": {
    '[aria-checked="true"] svg': "Inline effort segments indicate selection without a checkmark glyph.",
  },
  "transcript.cards": {
    ".acpmux-permission-card-leading": "QuestionCard has a text legend without a leading header icon.",
  },
  "transcript.toolgroup": {
    ".cv-tool__chevron": "Non-toggle tool rows have no trailing disclosure control.",
  },
};
for (const item of gridScenes) {
  item.absent = { ...absentBySurface[item.surface], ...item.absent };
  if (item.surface === "transcript.cards" && item.variant === "finished-open") {
    // SummaryCard.gallery.tsx sets column=true; both controls require !card.column. The column has
    // no title row either (#29895: it starts with Environment, as the popover does since #28744).
    item.absent[".acpmux-summary-card__fold--icon"] =
      "The inline summary column has no title row, so no popover fold icon.";
    item.absent[".acpmux-summary-card__title"] =
      "The inline summary column has no title row; it starts with Environment (#29895).";
    item.absent[".acpmux-summary-card__close"] = "The inline summary column has no popover close control.";
  }
}

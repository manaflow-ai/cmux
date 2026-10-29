import { sessionInfoGridScenes } from "./sessionInfoGridScenes";
import type { GridLine, GridMetric, GridPoint, GridScene } from "./gridLines";

const point = (selector: string, metric: GridMetric): GridPoint => ({ selector, metric });
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
  level: "warn",
  entry,
  variant,
  root,
  lines,
});
const plus = ".acpmux-composer-plus .acpmux-picker-button";

const placeholder = ".acpmux-md-placeholder";
const composer = (variant: string, text = placeholder, entry = "agent-pane.composer-row") => {
  const last = variant === "claude-auto" ? ".acpmux-mic" : ".acpmux-send:not(.acpmux-steer-now)";
  return scene(`composer/${variant}`, entry, variant, ".acpmux-composer-box", [
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
const running = composer("grid-running");
running.textIncludes = { selector: placeholder, text: "↵ steer · ⌘↵ queue" };

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
    left("edge: control inset", lead, "left", `calc(${token(`${surface}-lead-center`)} - ${token("icon-box")} / 2)`),
    left("lead", lead, "cx", token(`${surface}-lead-center`)),
    left("text", text, "text", token(`${surface}-text`)),
    trail(end, token(`${surface}-trail-center`)),
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

/** Promotion is per surface and requires a fleet measurement; no surface is assumed to pass. */
export const gridScenes: GridScene[] = [
  ...sessionInfoGridScenes,
  composer("claude-auto"),
  running,
  composer("grid-draft", ".acpmux-md p"),
  composer("attach-screenshot", placeholder, "agent-pane.composer"),
  scene("quiet-row", "agent-pane.composer-row", "claude-auto", ".acpmux-composer", [
    from(
      "edge: gap",
      ".acpmux-composer-foot",
      "top",
      point(".acpmux-composer-box", "bottom"),
      token("composer-quiet-row-gap"),
    ),
    value("row height", ".acpmux-composer-foot", "height", token("composer-quiet-row-height")),
    from("text", ".acpmux-mode-text", "text", point(".acpmux-composer-box", "left"), token("composer-quiet-row-text")),
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
    mid(".acpmux-mode-text", ".acpmux-composer-foot"),
    mid(".acpmux-model-detail:not(.acpmux-fit-label)", ".acpmux-composer-foot"),
    value("mid: ring", ".acpmux-context-ring svg", "cy", point(".acpmux-composer-foot", "cy")),
  ]),
  stack(
    "strip",
    "agent-pane.composer-strip",
    "project",
    ".acpmux-composer-strip",
    ".acpmux-location-leading svg",
    ".acpmux-location-label",
    ".acpmux-location-picker:last-child svg",
  ),
  stack(
    "trust-bar",
    "agent-pane.trust-ask",
    "grid-ask",
    ".acpmux-trust-ask",
    ".acpmux-trust-ask-icon",
    ".acpmux-trust-ask-text",
    ".acpmux-trust-ask-action:last-child",
  ),
  stack(
    "tray",
    "agent-pane.subagent-tray",
    "one-running",
    ".acpmux-agent-line",
    ".acpmux-lineage__icon",
    ".acpmux-summary-agent__name",
    ".acpmux-agent-line__stop-slot button",
  ),
  stack(
    "queue",
    "agent-pane.composer-row",
    "queued",
    ".acpmux-queued",
    ".acpmux-queued-kind",
    ".acpmux-queued-text",
    ".acpmux-queued-actions button:last-child",
  ),
  menu("menus/context", "ui.context-menu", "open", ".ui-context-menu", false),
  menu("menus/checkmarks", "ui.menu", "open", ".menu-gallery-popup", true),
  menu("pickers/model", "agent-pane.composer-pickers", "model-menu", ".acpmux-quick-menu", true),
  menu("pickers/account", "agent-pane.composer-pickers", "claude-direct-accounts", ".acpmux-quick-submenu", true),
  scene("pickers/effort", "agent-pane.composer-pickers", "effort-menu", ".acpmux-quick-efforts", [
    left("edge", ".acpmux-quick-effort-segment", "left", menuToken("highlight-inset")),
    left("lead: checked state", '[aria-checked="true"] svg', "cx", menuToken("state-x")),
    left("text", ".acpmux-quick-effort-segment", "text", menuToken("state-text-x")),
    trail(".acpmux-quick-effort-segment:last-child", menuToken("trailing")),
    mid(".acpmux-quick-effort-segment", ".acpmux-quick-effort-segment"),
  ]),
  scene("transcript/tool", "agent-pane.tool-row-column", "column", ".cv-tool", [
    left(
      "edge/lead",
      ".cv-tool__icon",
      "left",
      `calc(${token("transcript-icon-box")} - ${token("transcript-icon-box")})`,
    ),
    value("icon box", ".cv-tool__icon", "width", token("transcript-icon-box")),
    left("text", ".cv-tool__text", "text", token("transcript-text-gap")),
    trail(".cv-tool__chevron", token("transcript-action-trail-center")),
    mid(".cv-tool__text", ".cv-tool__icon"),
  ]),
  scene("transcript/actions", "agent-pane.reply-actions", "after-steer", ".cv-reply-actions", [
    trail(".cv-turn-time", token("transcript-action-trail-center")),
    value("action control", ".cv-iconbtn", "width", token("transcript-action-control")),
    ...centered(".cv-iconbtn svg", ".cv-iconbtn"),
    mid(".cv-turn-time", ".cv-iconbtn"),
  ]),
  card(
    "cards/permission",
    "agent-pane.permission-card",
    "grid-pending",
    ".acpmux-permission-card",
    ".acpmux-permission-request-icon",
    ".acpmux-permission-request-label",
    ".acpmux-permission-request-description",
    ".acpmux-permission-buttons button:last-child",
  ),
  card(
    "cards/question",
    "agent-pane.question-card",
    "pending-single",
    ".acpmux-question",
    ".acpmux-permission-card-leading",
    ".acpmux-question-prompt",
    ".acpmux-question-row",
    ".acpmux-question-submit",
  ),
  card(
    "cards/summary",
    "agent-pane.summary-card",
    "finished-open",
    ".acpmux-summary-card",
    ".acpmux-summary-card__fold--icon",
    ".acpmux-summary-card__title",
    ".acpmux-summary-text",
    ".acpmux-summary-card__close",
  ),
  // Session Info is measured above as one row surface, not as independent padded cards.
];

// These are omissions in the current component design, not selector fallbacks. All other
// missing selectors fail fixture coverage so renames cannot produce a green warning run.
const absentBySurface: Record<string, Record<string, string>> = {
  "trust-bar": { ".acpmux-trust-ask-icon": "TrustAsk renders text and buttons without a leading mark." },
  queue: { ".acpmux-queued-kind": "Ordinary queued prompts have no leading mark; only steering entries render kind." },
  "menus/context": {
    ".ui-menu-icon": "The context-menu open fixture has text-only actions.",
    ".ui-menu-shortcut, .ui-submenu-chevron": "These context actions have neither shortcut nor submenu.",
  },
  "pickers/effort": {
    '[aria-checked="true"] svg': "Inline effort segments indicate selection without a checkmark glyph.",
  },
  "cards/question": {
    ".acpmux-permission-card-leading": "QuestionCard has a text legend without a leading header icon.",
  },
  "transcript/tool": { ".cv-tool__chevron": "Non-toggle tool rows have no trailing disclosure control." },
};
for (const item of gridScenes) item.absent = absentBySurface[item.surface];

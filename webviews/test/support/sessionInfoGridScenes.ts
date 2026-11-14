import type { GridLine, GridMetric, GridScene } from "./gridLines";

const point = (selector: string, metric: GridMetric) => ({ selector, metric });
const token = (name: string) => `var(--grid-${name})`;
const line = (name: string, selector: string, metric: GridMetric, expected: string): GridLine => ({
  name,
  actual: point(selector, metric),
  origin: point(":scope", "left"),
  expected,
  all: true,
});
/// The body's left gutter for the sections' grips (sessionInfo.css --acpmux-session-info-grip-gutter):
/// every column on the left sits that much further in than the sidebar grid's own.
const GUTTER = "var(--acpmux-session-info-grip-gutter, 0px)";
/// The body's right gutter, which holds the sections' grips (--acpmux-session-info-grip-trail): every
/// trailing column sits that much further in than the sidebar grid's own.
const TRAIL = "var(--acpmux-session-info-grip-trail, 0px)";
const lead = (name: string, selector: string, nested = false) =>
  line(
    `${name}: lead cx`,
    selector,
    "cx",
    `calc(${token("sidebar-lead")} + ${token("icon-box")} / 2 + ${GUTTER}${nested ? ` + ${token("sidebar-depth-indent")}` : ""})`,
  );
const text = (name: string, selector: string, nested = false) =>
  line(
    `${name}: text x`,
    selector,
    "text",
    `calc(${token("sidebar-text")} + ${GUTTER}${nested ? ` + ${token("sidebar-depth-indent")}` : ""})`,
  );
/// A section's title: on the rows' icon column, with no icon of its own (Lucas, 2026-11-05, Session
/// Info lab: "the titles sit on the icon column").
const title = (name: string, selector: string) =>
  line(`${name}: text x`, selector, "text", `calc(${token("sidebar-lead")} + ${GUTTER})`);
const trail = (name: string, selector: string): GridLine => ({
  name: `${name}: trail cx`,
  actual: point(selector, "cx"),
  origin: point(":scope", "right"),
  inward: true,
  all: true,
  expected: `calc(${token("sidebar-trail-center")} + ${TRAIL})`,
});
const p = ".acpmux-session-info";
const section = (id: string) => `${p}-section[data-section="${id}"]`;
const scene = (variant: string, lines: GridLine[]): GridScene => ({
  surface: "session-info",
  level: "fail",
  entry: "agent-pane.chat-inspector",
  variant,
  root: `${p}__body`,
  lines,
});
export const sessionInfoGridScenes: GridScene[] = [
  scene("grid-expanded", [
    ...["environment", "connectors"].flatMap((id) => [
      lead(id, `${section(id)} ${p}-row > svg`),
      text(id, `${section(id)} ${p}-row__name`),
    ]),
    title("section headings", `${p}-section__title`),
    // No trail line for the fold chevron: #32817 moved it one grid gap after the title and hides it
    // at rest (cmux#32765), so it is not on the trailing column. SessionInfo.gallery.tsx
    // (chevronOnHoverAfterTitle) checks where it sits and that it shows on hover.
    lead("context rows", `${p}-context__swatch`),
    text("context rows", `${section("context")} ${p}-row__name`),
    lead("subagents", ".acpmux-lineage__icon"),
    text("subagents", ".acpmux-summary-agent__name"),
    lead("PR rows", `${p}-pr__icon`),
    text("PR rows", `${p}-pr__title`),
    trail("PR rows", `${p}-pr__more`),
    lead("source rows", `${p}-source__link > svg, ${p}-source > svg`),
    text("source rows", `${p}-source__label`),
    // A dev server is a task row of its own (ServersSection.tsx): its globe on the icon column, its
    // address on the text column. Its Stop takes the time's place on hover, off the trailing column.
    lead("servers", `${p}-task[data-kind="server"] ${p}-task__open > svg`),
    text("servers", `${p}-task[data-kind="server"] ${p}-task__address`),
    lead("tasks", `${p}-task:not([data-kind="server"]) ${p}-task__open > svg`),
    text("tasks", `${p}-task:not([data-kind="server"]) ${p}-task__open > ${p}-task__command`),
    lead("finished fold", `[data-section="tasks"] > ${p}-fold > svg`),
    text("finished fold", `[data-section="tasks"] > ${p}-fold`),
    {
      name: "row height",
      actual: point(`${section("environment")} ${p}-row`, "height"),
      expected: token("row"),
      all: true,
    },
    // One grid gap between every two sections, with no blocks and no hairlines (Lucas, 2026-11-05,
    // Session Info lab).
    {
      name: "environment to context: gap",
      actual: point(section("context"), "top"),
      origin: point(section("environment"), "bottom"),
      expected: token("gap"),
    },
  ]),
  ...["workflow-running", "workflow-agent-row-narrow"].map((variant) =>
    scene(variant, [
      text("workflow title", ".acpmux-workflow-task__name"),
      trail("workflow stop", ".acpmux-workflow-task__head > .acpmux-session-info-stop"),
      text("workflow phase", ".acpmux-workflow-phase__name"),
      trail("workflow phase", ".acpmux-workflow-phase__head > svg"),
      lead("workflow agents", ".acpmux-workflow-agent__icon", true),
      text("workflow agents", ".acpmux-workflow-agent__name", true),
    ]),
  ),
];

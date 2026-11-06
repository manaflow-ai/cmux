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
const lead = (name: string, selector: string, nested = false) =>
  line(
    `${name}: lead cx`,
    selector,
    "cx",
    `calc(${token("sidebar-lead")} + ${token("icon-box")} / 2${nested ? ` + ${token("sidebar-depth-indent")}` : ""})`,
  );
const text = (name: string, selector: string, nested = false) =>
  line(
    `${name}: text x`,
    selector,
    "text",
    nested ? `calc(${token("sidebar-text")} + ${token("sidebar-depth-indent")})` : token("sidebar-text"),
  );
const trail = (name: string, selector: string): GridLine => ({
  name: `${name}: trail cx`,
  actual: point(selector, "cx"),
  origin: point(":scope", "right"),
  inward: true,
  all: true,
  expected: token("sidebar-trail-center"),
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
    ...["environment", "connectors", "outputs"].flatMap((id) => [
      lead(id, `${section(id)} ${p}-row > svg`),
      text(id, `${section(id)} ${p}-row__name`),
    ]),
    lead("context heading", `${section("context")} ${p}-section__icon`),
    lead("connectors heading", `${section("connectors")} ${p}-section__icon`),
    text("section headings", `${p}-section__title`),
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
    lead("servers", `${p}-server__dot`),
    text("servers", `${p}-server__text > ${p}-task__command`),
    trail("servers", `${p}-server > ${p}-stop`),
    lead("tasks", `${p}-task__open > svg`),
    text("tasks", `${p}-task__open > ${p}-task__command`),
    trail("tasks", `${p}-task--command > ${p}-stop`),
    lead("finished fold", `[data-section="tasks"] > ${p}-fold > svg`),
    text("finished fold", `[data-section="tasks"] > ${p}-fold`),
    {
      name: "row height",
      actual: point(`${section("environment")} ${p}-row`, "height"),
      expected: token("row"),
      all: true,
    },
    // Session Info's own spacing, tighter than the transcript's (Leo, 2026-11-04: "there's a bit too big of
    // a gap between sections"): one base step inside a block, one inner gap between blocks.
    // Adjacent sections of one block in the default order (sectionOrder.ts DEFAULT_ORDER, #32850:
    // environment, context, usage, subagents, tasks, sources, changes, outputs, connectors).
    ...[
      ["environment", "context"],
      ["context", "usage"],
    ].map(([before, after]): GridLine => ({
      name: `${before} to ${after}: inner gap`,
      actual: point(section(after!), "top"),
      origin: point(section(before!), "bottom"),
      expected: token("base"),
    })),
    // The block runs that order draws: where it runs, what it runs, what it made, then Connectors
    // (where it runs) last.
    ...[
      ["about", "running"],
      ["running", "made"],
      ["made", "about"],
    ].map(([before, after]): GridLine => ({
      name: `${before} to ${after}: block gap`,
      actual: point(`${p}-slot[data-run-start][data-group="${after}"]`, "top"),
      origin: point(`${p}-slot[data-run-end][data-group="${before}"]`, "bottom"),
      expected: token("gap-inner"),
    })),
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

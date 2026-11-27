// The kit's scene-parity variants (bare Button, Row passthrough and detail subtitle, xs Pill, the
// grid names, the full radius) are additive: every render without them is the markup it was before
// they existed, captured from the base this landed on.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createRef, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Button, GRID, Pill, RADII, Row, grid, radius } from "./index";

const html = (node: ReactNode) => renderToStaticMarkup(<>{node}</>);
const repo = join(import.meta.dir, "../../..");

const EXISTING: Record<string, ReactNode> = {
  buttonDefault: <Button>Save</Button>,
  buttonGhostIcon: (
    <Button variant="ghost" size="sm" icon danger aria-label="x" className="extra">
      x
    </Button>
  ),
  rowAction: <Row title="Inbox" subtitle="3 waiting" leading="L" trailing="T" selected onSelect={() => {}} />,
  rowStatic: <Row title="Static" density="comfortable" className="c" />,
  rowLabel: <Row title="Static" label="Read me" />,
  pillDefault: <Pill>12</Pill>,
  pillSm: (
    <Pill size="sm" tone="success" icon="i" className="c">
      Merged
    </Pill>
  ),
};

const BEFORE: Record<string, string> = {
  buttonDefault:
    '<button type="button" tabindex="0" data-variant="subtle" data-size="md" class="ui-button ui-btn">Save</button>',
  buttonGhostIcon:
    '<button type="button" tabindex="0" data-variant="ghost" data-size="sm" data-icon="" data-danger="" aria-label="x" class="ui-button ui-btn extra">x</button>',
  rowAction:
    '<li class="kit-row-item"><button type="button" class="kit-row" data-density="compact" data-selected="" aria-current="true"><span class="kit-row-lead">L</span><span class="kit-row-text"><span class="kit-row-title">Inbox</span><span class="kit-row-subtitle">3 waiting</span></span><span class="kit-row-trail">T</span></button></li>',
  rowStatic:
    '<li class="kit-row-item"><div class="kit-row c" data-density="comfortable"><span class="kit-row-text"><span class="kit-row-title">Static</span></span></div></li>',
  rowLabel:
    '<li class="kit-row-item"><div class="kit-row" data-density="compact"><span class="ui-sr-only">Read me</span><span class="kit-row-body" aria-hidden="true"><span class="kit-row-text"><span class="kit-row-title">Static</span></span></span></div></li>',
  pillDefault: '<span class="kit-pill" data-tone="neutral" data-size="md">12</span>',
  pillSm: '<span class="kit-pill c" data-tone="success" data-size="sm">iMerged</span>',
};

test("callers that pass none of the new props render the markup they did before", () => {
  for (const [name, node] of Object.entries(EXISTING)) expect([name, html(node)]).toEqual([name, BEFORE[name]!]);
});

test("a bare Button carries only the caller's class", () => {
  const markup = html(
    <Button bare className="cmux-app-scene-button" variant="solid" size="lg">
      Go
    </Button>,
  );
  expect(markup).toBe('<button type="button" tabindex="0" class="cmux-app-scene-button">Go</button>');
});

test("a Row passes its ref and other props to the row element, and marks a detail subtitle", () => {
  const markup = html(
    <Row title="Move me" subtitle="detail" subtitleSize="detail" draggable data-reorder="k" onSelect={() => {}} />,
  );
  expect(markup).toContain('draggable="true"');
  expect(markup).toContain('data-reorder="k"');
  expect(markup).toContain('data-subtitle-size="detail"');
  expect(html(<Row title="x" subtitleSize="caption" />)).not.toContain("data-subtitle-size");
  // A static row's label still names it; a button row takes aria-label from either.
  expect(html(<Row title="x" aria-label="named" onSelect={() => {}} />)).toContain('aria-label="named"');
  const ref = createRef<HTMLElement>();
  expect(html(<Row ref={ref} title="x" />)).toBe(html(<Row title="x" />));
});

test("an xs Pill is a size like the others", () => {
  expect(html(<Pill size="xs">3</Pill>)).toBe('<span class="kit-pill" data-tone="neutral" data-size="xs">3</span>');
  const css = readFileSync(join(import.meta.dir, "kit.css"), "utf8");
  const xs = css.slice(css.indexOf('.kit-pill[data-size="xs"] {'));
  for (const value of ["var(--grid-icon-box)", "var(--grid-base)", "var(--text-detail)", "currentColor 14%"])
    expect(xs.slice(0, 600)).toContain(value);
});

test("the grid names are the layout grid's own variables, and full is a radius token", () => {
  const layout = JSON.parse(readFileSync(join(repo, "schemas/layout-grid/layout-grid.json"), "utf8")) as {
    metrics: { name: string }[];
  };
  const names = new Set(layout.metrics.map((metric) => metric.name));
  const desktop = readFileSync(join(repo, "webviews/src/pages/shared/desktop.css"), "utf8");
  for (const name of GRID) {
    expect([name, names.has(name)]).toEqual([name, true]);
    expect(desktop).toContain(`--grid-${name}:`);
  }
  expect(grid("gap")).toBe("var(--grid-gap)");
  expect(radius("full")).toBe("var(--ds-radius-full)");
  expect(RADII.find((entry) => entry.name === "full")?.px).toBe(999);
  expect(desktop).toContain("--ds-radius-full: 999px;");
  // Tailwind's own rounded-full is left alone.
  expect(readFileSync(join(repo, "webviews/src/ui/theme.generated.css"), "utf8")).not.toContain("--radius-full");
});

test("a named static Row exposes its secondary action outside the replacement label", () => {
  const row = html(<Row title="Inbox" label="Inbox, waiting" hoverActions={<Button>Pin</Button>} />);
  expect(row).toContain('aria-hidden="true"><span class="kit-row-text ui-reveal-text"');
  expect(row).toContain('</div><span class="kit-row-actions ui-reveal"><button');
  expect(html(<Row title="Inbox" hoverActions={false} />)).toBe(html(<Row title="Inbox" />));
});

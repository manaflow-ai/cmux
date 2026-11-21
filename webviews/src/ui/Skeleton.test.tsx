// ui/Skeleton: a loading placeholder that is decoration to assistive tech (aria-hidden), breathes on the
// shared `cmux-breathe` clock rather than a pulse of its own, and holds still under Reduce Motion, the
// app's motion setting and static status indicators. The Apps grid's placeholders are this component.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { Skeleton } from "./Skeleton";
import { SHARED_LOOP_KEYFRAMES } from "./spinnerClock";

const css = readFileSync(join(import.meta.dir, "skeleton.css"), "utf8");

test("a skeleton is hidden from assistive tech and takes the caller's class and shape", () => {
  const html = renderToStaticMarkup(
    <>
      <Skeleton className="apps-skeleton-icon" />
      <Skeleton shape="line" style={{ width: "58%" }} />
      <Skeleton shape="circle" aria-hidden={false} />
    </>,
  );
  expect(html).toBe(
    '<span aria-hidden="true" class="ui-skeleton apps-skeleton-icon" data-shape="block"></span>' +
      '<span aria-hidden="true" style="width:58%" class="ui-skeleton" data-shape="line"></span>' +
      '<span aria-hidden="false" class="ui-skeleton" data-shape="circle"></span>',
  );
});

test("it breathes on the shared clock, never a pulse of its own", () => {
  expect(SHARED_LOOP_KEYFRAMES.has("cmux-breathe")).toBe(true);
  expect(css).toMatch(/\.ui-skeleton\s*\{\s*animation: cmux-breathe var\(--cmux-breath-period/);
  expect(css).not.toMatch(/@keyframes/);
  expect(css).not.toContain("pulse");
});

test("it holds still under Reduce Motion, the app's motion setting and static indicators", () => {
  const rule = /@media \(prefers-reduced-motion: no-preference\) \{\s*([^{]+)\{\s*animation: cmux-breathe/.exec(css);
  expect(rule).not.toBeNull();
  const selector = rule![1]!;
  for (const off of ['[data-status-indicators="static"]', '[data-cmux-motion="off"]', '[data-cmux-motion="reduced"]'])
    expect(selector).toContain(off);
  expect(selector.trim().startsWith(":root:not(")).toBe(true);
  // The only animation in the sheet is that gated one.
  expect(css.match(/animation:/g)).toHaveLength(1);
});

test("the look weighs nothing, so a caller's size and radius win whichever sheet loads first", () => {
  expect(css).toContain(":where(.ui-skeleton) {");
  expect(css).not.toMatch(/^\.ui-skeleton\s*\{/m);
});

test("the Apps grid draws its placeholders with Skeleton and keeps only their sizes", () => {
  const page = readFileSync(join(import.meta.dir, "../pages/apps/AppsPage.tsx"), "utf8");
  const styles = readFileSync(join(import.meta.dir, "../pages/apps/styles.css"), "utf8");
  for (const part of ["apps-skeleton-icon", "apps-skeleton-line wide", "apps-skeleton-line", "apps-skeleton-footer"])
    expect(page).toContain(`<Skeleton className="${part}" />`);
  expect(styles).not.toContain("cmux-breathe");
});

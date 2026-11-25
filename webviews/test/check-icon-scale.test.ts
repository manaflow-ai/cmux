// The icon-scale lint (scripts/check-icon-scale.ts): icons draw at 12, 14, 16 or 20 (artwork 24+),
// unless the line says icon-scale-allow: <reason>; older debt is in scripts/icon-scale-baseline.tsv.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";
import { findAllIcons, findCssIcons, findTsxIcons, overBaseline, readBaseline } from "../scripts/check-icon-scale";

test("the webviews draw no off-scale icon beyond the recorded baseline", () => {
  const baseline = readBaseline(readFileSync(join(import.meta.dir, "../scripts/icon-scale-baseline.tsv"), "utf8"));
  expect(overBaseline(findAllIcons(), baseline).map((f) => `${f.file}:${f.line} ${f.source}`)).toEqual([]);
});

test("a component size, a square svg and a square icon box off the scale fail", () => {
  const tsx = `
<Check size={11} />
<Check size={12} />
<input size={1} />
<Avatar size={32} />
<svg viewBox="0 0 16 16" width="13" height="13" />
<svg width={16} height={16} />
<svg width="80" height="20" />
{/* icon-scale-allow: inside a 12 mark */}
<Check size={10} />
`;
  expect(findTsxIcons("a.tsx", tsx).map((f) => `${f.line} ${f.px}`)).toEqual(["2 11", "6 13"]);
});

test("css reads square boxes named as icons, not dots, buttons or allowed rules", () => {
  const css = `
.x-search svg { width: 13px; height: 13px; }
.x-chevron { width: 12px; height: 12px; }
.x-unread::before { width: 7px; height: 7px; }
.x-icon-button { width: 22px; height: 22px; }
.x-glyph { width: 18px; height: 10px; }
.y-icon {
  /* icon-scale-allow: the composer's 18 set */
  width: 18px;
  height: 18px;
}
.z-glyph{width:15px;height:15px}
`;
  expect(findCssIcons("a.css", css).map((f) => `${f.line} ${f.px}`)).toEqual(["2 13", "12 15"]);
});

test("the baseline lets recorded debt stay and refuses more of it", () => {
  const css = ".a svg { width: 13px; height: 13px; }\n.b svg { width: 13px; height: 13px; }\n";
  const found = findCssIcons("a.css", css);
  expect(overBaseline(found, readBaseline("a.css\t13\t2\n"))).toEqual([]);
  expect(overBaseline(found, readBaseline("a.css\t13\t1\n")).length).toBe(2);
});

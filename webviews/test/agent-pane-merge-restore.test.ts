// The #21331 branch was rebased onto a tree without #21194, #21344 and #21383, and dropped their
// agent pane wiring when it merged: the Chief Dock never mounted, the Debug Settings turn footer
// placement did nothing, disclosures shared one bucket across chats, and the sent-image slot lost
// its CSS. Each check below failed on feat-cmux-next until it was restored.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";

const read = (path: string) => readFileSync(join(import.meta.dir, "../src/agent-session/acpmux", path), "utf8");
const app = read("App.tsx");

const styleRules = (css: string) => {
  const dom = new JSDOM("<!doctype html>");
  const style = dom.window.document.createElement("style");
  style.textContent = css;
  dom.window.document.head.append(style);
  const flatten = (rules: CSSRuleList): CSSRule[] =>
    [...rules].flatMap((rule) =>
      "cssRules" in rule ? [rule, ...flatten((rule as CSSGroupingRule).cssRules)] : [rule],
    );
  return flatten(style.sheet!.cssRules) as CSSStyleRule[];
};
const conversation = styleRules(read("conversation/conversation.css"));
const rule = (selector: string) => conversation.find((r) => r.selectorText === selector);

test("a sent image keeps its 120px slot while it loads (#21383)", () => {
  const slot = rule(".cv-user__image-placeholder");
  expect(slot?.style.width).toBe("120px");
  expect(slot?.style.height).toBe("120px");
});

test("a loaded reply image has no entrance animation", () => {
  expect(rule(".cv-img--enter")).toBeUndefined();
});

test("the turn footer actions sit on the left, and Debug Settings can put them on the right (#21344)", () => {
  expect(rule(".cv-turn-actions")?.style.justifyContent).toBe("flex-start");
  expect(rule(':root[data-turn-actions-placement="right"] .cv-turn-actions')?.style.justifyContent).toBe("flex-end");
  expect(app).toContain("configureTurnActionsPlacement(theme.turnActionsPlacement)");
});

test("disclosure rows are keyed by their chat (#21344)", () => {
  expect(app).toContain("<ToolRows row={row} sessionId={sessionId} />");
  expect(app).toContain("<EditedFilesCard row={row} sessionId={sessionId} onOpenDiff={onOpenDiff} />");
});

test("the quick surface mounts the Chief Dock when its experiment is on (#21194)", () => {
  expect(app).toMatch(/experimentArm\(chiefDock\) === "on"/);
  expect(app).toContain("chiefDock={quickChiefDock}");
});

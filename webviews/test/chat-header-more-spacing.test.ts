// The chat header's tools are one square each, sized from the layout grid, and the chat menu's trigger is the app's
// horizontal ellipsis in that same square (Leo 2026-11-04: "i guess we ought to just make this a horizontal
// ellipsis?" and "at least give our button square padding. so all those things are proportional"). The gallery's
// agent-pane.header-tools/grouped-controls and density-* variants measure it in a browser.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { HEADER_SYMBOLS } from "../src/agent-session/acpmux/header/headerSymbols";

const HEADER = join(import.meta.dir, "../src/agent-session/acpmux/header");
const css = readFileSync(join(HEADER, "header.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

function declarations(selector: string): Map<string, string> {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = css.match(new RegExp(`(?:^|\\})\\s*${escaped}\\s*\\{([^{}]*)\\}`, "m"));
  expect(match, `header.css has a rule for ${selector}`).toBeTruthy();
  return new Map(
    match![1]!
      .split(";")
      .map((part) => {
        const at = part.indexOf(":");
        return at < 0 ? [] : [part.slice(0, at).trim(), part.slice(at + 1).trim()];
      })
      .filter((pair): pair is [string, string] => pair.length === 2 && pair[0] !== ""),
  );
}

test("the chat menu's trigger draws the horizontal ellipsis, the app's other more buttons' glyph", () => {
  const source = readFileSync(join(HEADER, "ChatHeaderTools.tsx"), "utf8");
  expect(source).toContain('className={triggerClassName ?? "acpmux-header-tool acpmux-header-more"}');
  expect(source).toContain('<HeaderIcon name="action.more" size={HEADER_GLYPH} />');
  expect(source).not.toContain("action.more.vertical");
  expect(readFileSync(join(HEADER, "HeaderIcon.tsx"), "utf8")).not.toContain("rotate");
  expect(HEADER_SYMBOLS["action.more"]).toBe("ellipsis");
  expect(HEADER_SYMBOLS["action.more.vertical"]).toBeUndefined();
});

test("every tool is one square from the grid tokens, the ⋯ included, with a token radius and gap", () => {
  const tool = declarations(".acpmux-header-tool");
  const size = "var(--acpmux-header-tool-size,var(--grid-pill,24px))";
  expect(tool.get("width")).toBe(size);
  expect(tool.get("height")).toBe(size);
  expect(tool.get("padding")).toBe("0");
  expect(tool.get("justify-content")).toBe("center");
  expect(tool.get("align-items")).toBe("center");
  expect(tool.get("border-radius")).toBe("var(--ds-radius-md,6px)");
  // No rule gives the ⋯ its own box or margin. A rule may still target it for something else: #56616's warning dot
  // positions the ⋯ (position: relative) so its ::after sits in the corner, and that moves nothing.
  const boxProperty =
    /(?:^|[;{\s])(?:width|height|min-width|min-height|max-width|max-height|padding[\w-]*|margin[\w-]*|inline-size|block-size|flex(?:-basis|-grow|-shrink)?)\s*:/;
  const moreRules = [...css.matchAll(/([^{}]*\.acpmux-header-more(?![\w-])[^{}]*)\{([^{}]*)\}/g)].filter((rule) =>
    rule[1]!.split(",").some((selector) => /\.acpmux-header-more(?![\w-])\s*$/.test(selector.trim())),
  );
  for (const rule of moreRules) expect(rule[2]!, rule[1]!.trim()).not.toMatch(boxProperty);
  const gap = "var(--acpmux-header-tool-gap,var(--grid-half-step))";
  expect(declarations(".acpmux-header-tools").get("gap")).toBe(gap);
  expect(declarations(".acpmux-header-tool-group").get("gap")).toBe(gap);
});

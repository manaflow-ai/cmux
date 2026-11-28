// The live line's subagents count (summary/LiveCount.tsx) leads with a 12 px mark. Without a slot the
// mark's left edge sat on the icon column and the gallery's icon-column rule read the row 2 px left of
// it (a sub-slot glyph is centred in the 16 px slot): "row thinking-live: the lead edge at x 14, the
// column is at 16 (-2 px)" across agent-pane.subagent-tray, subagents and composer-turn-cycle.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { leadEdge } from "../../../gallery/invariants";

const css = readFileSync(new URL("./conversation.css", import.meta.url), "utf8");
const liveCount = readFileSync(new URL("../summary/LiveCount.tsx", import.meta.url), "utf8");

test("the live count's mark centres in the glyph slot, its lead edge on the icon column", () => {
  const rule = css.match(/\.cv-thinking > \.acpmux-live-count > svg \{([^}]*)\}/)?.[1] ?? "";
  const inset = rule.match(/margin-inline-start:\s*calc\(\(var\(--cv-glyph-slot\) - (\d+)px\) \/ 2\)/);
  expect(inset).not.toBeNull();
  const markSize = Number(liveCount.match(/<Icon name=\{LIVE_COUNT_ICON\} size=\{(\d+)\}/)?.[1]);
  expect(Number(inset?.[1])).toBe(markSize);
  const column = 16;
  const slot = 16;
  const left = column + (slot - markSize) / 2;
  expect(leadEdge({ left, width: markSize })).toBe(column);
  expect(leadEdge({ left: column, width: markSize })).toBe(column - 2);
});

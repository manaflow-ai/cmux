// After Jump to latest lands while a turn runs, what streams on keeps to the room over the bottom
// stack (VirtualTranscript `chaseHeld`) "until the reader sends". A send made scrolled up clears it
// through stopJump; a send made from the latest row skipped stopJump and left the hold to the
// placement pass, which clears it only on its last branch and only when the row count grew. A send
// whose rows landed on a ride, a fold or a resize pass, or replaced a row, kept the reply held to
// the room. The send effect's from-latest branch clears the hold itself, as its scrolled-up branch
// does. Read from the source: the whole pane is needed to reach this state in a page.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../src/agent-session/acpmux/VirtualTranscript.tsx", import.meta.url), "utf8");

test("a send from the latest row ends Jump to latest's hold on the chase", () => {
  const start = source.indexOf("const fromLatest = followingRef.current && jumpTarget.current === undefined;");
  expect(start).toBeGreaterThan(0);
  const branch = /if \(fromLatest\) \{([\s\S]*?)\} else stopJump\(\);/.exec(source.slice(start))?.[1] ?? "";
  expect(branch).toContain("stopScroll(node);");
  expect(branch).toMatch(/chaseHeld\.current = false;/);
});

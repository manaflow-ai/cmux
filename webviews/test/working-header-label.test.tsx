// l10n-allow-file: assertions for the English running-turn header.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { WorkingFor } from "../src/agent-session/acpmux/conversation/WorkingFor";

const row: AcpmuxRow = { id: "working-prompt", version: 1, kind: "working", at: 1000 };
const text = (elapsed: number) =>
  renderToStaticMarkup(<WorkingFor row={row} now={() => row.at + elapsed} />)
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

// One shape from the first frame: "Working for <1s", never a bare "Working" that swaps to a time
// at its first second (Leo, 2026-11-25: "i think it was replacing the "worked for" as it went").
test("the header says Working for <1s before the first elapsed second", () => {
  expect(text(0)).toBe("Working for &lt;1s");
  expect(text(999)).toBe("Working for &lt;1s");
});

test("the header adds elapsed time from the first second", () => {
  expect(text(1000)).toBe("Working for 1s");
  expect(text(15_000)).toBe("Working for 15s");
});

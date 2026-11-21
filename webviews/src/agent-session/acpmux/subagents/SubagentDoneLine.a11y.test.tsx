// l10n-allow-file: test fixture names, not shipped UI.
// A read-only transcript's "Subagent finished" line (issue #39962): with no view to open, its name
// is a plain chip, and that chip's text must still reach assistive tech.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { SubagentDoneLine } from "./SubagentDoneLine";
import type { Subagent } from "./subagentFold";

const agent: Subagent = {
  id: "chat/toolu_explore",
  parent: null,
  name: "general-purpose",
  task: "Explore the daemon",
  state: "completed",
  startedAt: 2_000,
  endedAt: 82_000,
};
const row: AcpmuxRow = { id: "done", kind: "subagent-done", version: 1, at: 82_000, subagents: [agent] };

/// The text a screen reader reaches: aria-hidden subtrees dropped, then the tags.
function accessibleText(html: string): string {
  let out = html;
  for (;;) {
    const next = out.replace(/<(\w+)[^>]*aria-hidden="true"[^>]*>(?:(?!<\1[\s>])[\s\S])*?<\/\1>/, "");
    if (next === out) break;
    out = next;
  }
  return out
    .replace(/<[^>]+>/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

test("a read-only finished line reads its task name to assistive tech", () => {
  const html = renderToStaticMarkup(<SubagentDoneLine row={row} />);
  expect(html).toContain("Explore the daemon");
  // No copy of the name is hidden from assistive tech, and the row's div carries no aria-label it ignores.
  expect(html).not.toMatch(/aria-hidden="true"[^>]*>Explore the daemon</);
  expect(html).not.toMatch(/<div[^>]*cv-subagent-done[^>]*aria-label=/);
  expect(accessibleText(html)).toContain("Explore the daemon");
});

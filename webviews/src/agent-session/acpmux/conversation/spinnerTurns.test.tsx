// The transcript's running rows (compaction, tool groups, MCP calls, a message card, command and
// shell rows) draw `Spinner`: Leo 2026-10-20 ("why do these things not spin?") saw "Compacting the
// conversation…" with a ring that never moved, because no rule animated it. Agent work marks itself
// `data-working` so the working look (WORKING-LOOK, conversation.css) can draw it; the loops
// themselves are checked in a browser (test/static-status-loops.test.ts).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { CompactionNote } from "./CompactionNote";
import { Spinner } from "./icons";

test("a running compaction draws the transcript spinner", () => {
  const html = renderToStaticMarkup(<CompactionNote compaction={{ state: "running" }} />);
  expect(html).toContain('class="cv-spinner"');
  expect(html).toContain("data-working");
});

test("a spinner keeps its own class next to the caller's", () => {
  const html = renderToStaticMarkup(<Spinner className="acpmux-harness-spinner" />);
  expect(html).toContain('class="cv-spinner acpmux-harness-spinner"');
});

test("a loading spinner (a harness check) never takes the working dot", () => {
  const html = renderToStaticMarkup(<Spinner loading />);
  expect(html).not.toContain("data-working");
  expect(html).not.toContain("cv-spinner__dot");
});

// `debug.agent_pane seed_rows` with `fixture: "link"`: a turn whose reply links a pull request on a
// synthetic page, so a capture that clicks it never shows a live GitHub page (cmux#28544).
import { expect, test } from "bun:test";
import { LINKED_PAGE, linkRows } from "../src/agent-session/acpmux/linkFixture";

test("the reply links the synthetic page, never a live github.com one", () => {
  const rows = linkRows(Date.UTC(2026, 9, 30, 22));
  const reply = rows.find((row) => row.kind === "assistant");
  expect(reply?.kind === "assistant" && reply.text).toContain(`](${LINKED_PAGE})`);
  expect(new URL(LINKED_PAGE).hostname).toBe("example.com");
  expect(rows.some((row) => "text" in row && String(row.text).includes("github.com"))).toBe(false);
});

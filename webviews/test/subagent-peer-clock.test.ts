// l10n-allow-file: test fixture subagent names, not shipped UI.
// A subagent's start and end are the session's event times; a peer's session runs on its own
// clock (the snapshot's `clockOffsetMs`: this computer's clock minus the session's). The group line,
// its rows, the agents pill and the summary list timed a running subagent against this computer's
// clock, so on a peer a minute ahead it read "0s" the whole time (and a minute behind, a minute
// too long), while the turn's own clock was right (conversation/turns.ts). They now count in the
// session's clock.
import { expect, test } from "bun:test";
import { type Context, createContext, createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import * as group from "../src/agent-session/acpmux/subagents/SubagentGroup";

// Read loosely so a pane without the context fails on the times, not on the import.
const { SubagentGroupHeader } = group;
const SubagentClockContext =
  (group as { SubagentClockContext?: Context<number> }).SubagentClockContext ?? createContext(0);

const header = (offset: number, startedAt: number) => {
  const row: AcpmuxRow = {
    id: "subagents-1",
    version: 1,
    at: startedAt,
    kind: "subagents",
    subagents: [{ id: "a1", parent: null, name: "Explore", state: "running", startedAt }],
  };
  const html = renderToStaticMarkup(
    createElement(
      SubagentClockContext.Provider,
      { value: offset },
      createElement(SubagentGroupHeader, { row, expanded: false, onToggle: () => {} }),
    ),
  );
  return html.match(/class="cv-subagents__time">([^<]*)</)?.[1];
};

test("a running subagent on a session a minute ahead counts in the session's clock", () => {
  const offset = -60_000;
  const sessionNow = Date.now() - offset;
  expect(header(offset, sessionNow - 5_000)).toBe("5s");
});

test("a running subagent on a session a minute behind does not read a minute too long", () => {
  const offset = 60_000;
  const sessionNow = Date.now() - offset;
  expect(header(offset, sessionNow - 5_000)).toBe("5s");
});

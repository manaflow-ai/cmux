// l10n-allow-file: test fixtures, not shipped UI.
// One action row per turn, at its bottom: no reply inside a turn draws its own row, and the turn's
// footer copies the whole turn, its replies and each run of tool calls as its top-level line, as
// Claude Code desktop does (Leo, 2026-10-31: "claude code doesn't have individual copy pastable
// things for the entire thing, only the bottom. ironically we have literally the complete opposite.
// so let's invert our behaviour. btw yes claude code desktop does copy all of it incl. tool call top
// level things"). A turn of tool calls alone draws no Copy and no Read aloud.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { PendingSteer } from "../src/agent-session/acpmux/conversation/PendingSteer";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";
import { TurnFooter } from "../src/agent-session/acpmux/conversation/TurnRows";
import { turnCopyText } from "../src/agent-session/acpmux/conversation/turnCopy";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import { hasReplyActions, nextDrawnRow, type AcpmuxActivity, type AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (id: string, kind: string, at: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind,
  ...fields,
});
const reply = (id: string, at: number, text: string) => row(id, "assistant", at, { text });
const send: AcpmuxActivity = {
  kind: "tool",
  text: "acpmux send --no-wait coord-deputy 'Merged #4182.'",
  tool: {
    id: "send-1",
    title: "acpmux send --no-wait coord-deputy 'Merged #4182.'",
    kind: "execute",
    status: "completed",
    command: "acpmux send --no-wait coord-deputy 'Merged #4182.'",
    output: "queued",
  },
};
const message = (text: string) => ({
  kind: "message" as const,
  message: { name: "gcp-codex-lane-12", sessionId: "lane-12", text, raw: text },
});

const BEFORE_STEER =
  "I gave team access to the cloud-idle helper, which already knows our Freestyle setup, so anyone on the team can open the team's machines.";
const ANSWER =
  "The review of the Stop fix is still running and has no verdict yet; I told the lane it need not ask again.";

const marked = (rows: readonly AcpmuxRow[]) =>
  Object.fromEntries(
    rows.flatMap((one, index) =>
      one.kind === "assistant" ? [[one.id, hasReplyActions(one, nextDrawnRow(rows, index))]] : [],
    ),
  );
const read: AcpmuxActivity = {
  kind: "tool",
  text: "Read /r/turns.ts",
  tool: {
    id: "read-1",
    title: "Read /r/turns.ts",
    kind: "read",
    status: "completed",
    locations: [{ path: "/r/turns.ts" }],
  },
};
const run = (id: string): AcpmuxActivity => ({
  kind: "tool",
  text: "git status",
  tool: { id, title: "git status", kind: "execute", status: "completed", command: "git status" },
});
const t = translatorFor("en");

test("no reply inside a turn draws its own row, before a steer, a message or work", () => {
  const source = [
    row("u1", "user", 0, { text: "Give the team access to the helper." }),
    reply("a1", 1_000, BEFORE_STEER),
    row("s1", "user", 2_000, { text: "Also tell Lawrence.", steer: "landed" }),
    row("m1", "user", 2_500, { text: "Still no merge SHA.", incoming: message("Still no merge SHA.") }),
    row("t1", "activity", 3_000, { items: [send], toolCount: 1 }),
    reply("a2", 4_000, ANSWER),
    row("f1", "turnSummary", 5_000, { durationMs: 5_000, toolCount: 1, status: "completed" }),
  ];
  expect(marked(turnView(source, new Set([`${WORKED}-u1`]), { now: 10_000 }))).toEqual({ a1: false, a2: false });
  const running = source.slice(0, 5);
  expect(marked(turnView(running, new Set(), { now: 10_000, working: true }))).toEqual({ a1: false });
});

test("the footer copies the whole turn: every reply in order and each tool run's top-level line", () => {
  const rows = turnView(
    [
      row("u1", "user", 0, { text: "Report the merge." }),
      reply("a1", 1_000, BEFORE_STEER),
      row("t1", "activity", 2_000, { items: [run("c1")], toolCount: 1 }),
      row("t2", "activity", 2_100, { items: [run("c2"), read], toolCount: 2 }),
      row("s1", "user", 3_000, { text: "Also tell Lawrence.", steer: "landed" }),
      row("t3", "activity", 3_500, { items: [read], toolCount: 1 }),
      reply("a2", 4_000, ANSWER),
      row("f1", "turnSummary", 5_000, { durationMs: 5_000, toolCount: 4, status: "completed" }),
    ],
    new Set(),
    { now: 10_000 },
  );
  const footer = rows.find((one) => one.kind === "turnSummary")!;
  expect(turnCopyText(t, footer.turnCopy!)).toBe(
    [BEFORE_STEER, "Ran 2 commands, read a file", "Read /r/turns.ts", ANSWER].join("\n\n"),
  );
  const html = renderToStaticMarkup(<TurnFooter row={footer} />);
  expect(html).toContain('aria-label="Copy"');
});

test("a turn of tool calls alone has no Copy and no Read aloud", () => {
  const rows = turnView(
    [
      row("u1", "user", 0, { text: "List the agents." }),
      row("t1", "activity", 1_000, { items: [run("c1")], toolCount: 1 }),
      row("f1", "turnSummary", 2_000, { durationMs: 2_000, toolCount: 1, status: "completed" }),
    ],
    new Set(),
    { now: 10_000 },
  );
  const footer = rows.find((one) => one.kind === "turnSummary")!;
  expect(footer.turnCopy).toBeUndefined();
  const html = renderToStaticMarkup(<TurnFooter row={footer} />);
  expect(html).not.toContain('aria-label="Copy"');
  expect(html).toContain('class="cv-turn-time"');
});

test("a steer that waits for the agent offers Copy beside Send now", () => {
  const html = renderToStaticMarkup(
    <PendingSteer
      row={row("s1", "user", 1_000, { text: "Use the cache dir", steer: "waiting", steerPromptId: "p-copy" })}
      send={async () => true}
    />,
  );
  expect(html).toContain('aria-label="Copy"');
  expect(html).toContain("cv-user__send-now");
});

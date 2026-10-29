// l10n-allow-file: test fixtures, not shipped UI.
// Every reply keeps its own action row, whatever follows it (Leo, 2026-10-29: "i feel like im
// frequently missing the copy/whatever buttons on these steers... but claude code allows those
// buttons in these situations. let's have those"). A reply followed by a steer, another agent's
// message or a sent message drew none: the turn's footer, the only action row, sits at the turn's
// end and copies its answer alone. The turn's answer keeps the footer as its row, and a running
// turn's latest reply waits for it.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import * as messageActions from "../src/agent-session/acpmux/conversation/MessageActions";
import { PendingSteer } from "../src/agent-session/acpmux/conversation/PendingSteer";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { layoutConversation, type AcpmuxActivity, type AcpmuxRow } from "../src/agent-session/acpmux/model";

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
  Object.fromEntries(rows.filter((one) => one.kind === "assistant").map((one) => [one.id, one.replyActions === true]));

test("a reply followed by a steer keeps its row; the turn's answer keeps the footer", () => {
  const rows = turnView(
    [
      row("u1", "user", 0, { text: "Give the team access to the helper." }),
      reply("a1", 1_000, BEFORE_STEER),
      row("s1", "user", 2_000, { text: "Also tell Lawrence.", steer: "landed" }),
      row("t1", "activity", 3_000, { items: [send], toolCount: 1 }),
      reply("a2", 4_000, ANSWER),
      row("f1", "turnSummary", 5_000, { durationMs: 5_000, toolCount: 1, status: "completed" }),
    ],
    new Set(),
    { now: 10_000 },
  );
  expect(marked(rows)).toEqual({ a1: true, a2: false });
  const footer = rows.find((one) => one.kind === "turnSummary")!;
  expect(footer.answerId).toBe("a2");
});

test("a reply followed by another agent's message keeps its row", () => {
  const rows = turnView(
    [
      row("u1", "user", 0, { text: "Check on the review." }),
      reply("a1", 1_000, BEFORE_STEER),
      row("m1", "user", 2_000, { text: "Still no merge SHA.", incoming: message("Still no merge SHA.") }),
      reply("a2", 3_000, ANSWER),
      row("f2", "turnSummary", 4_000, { durationMs: 1_000, toolCount: 0, status: "completed" }),
    ],
    new Set(),
    { now: 10_000 },
  );
  expect(marked(rows)).toEqual({ a1: true, a2: false });
});

test("in a running turn a reply followed by a sent message keeps its row; the latest one waits", () => {
  const source = [
    row("u1", "user", 0, { text: "Report the merge." }),
    reply("a1", 1_000, BEFORE_STEER),
    row("t1", "activity", 2_000, { items: [send], toolCount: 1 }),
    reply("a2", 3_000, ANSWER),
  ];
  for (const options of [
    { working: true },
    { working: true, liveRuns: true, lineBelow: true },
    { working: true, lineBelow: true },
  ]) {
    const rows = turnView(source, new Set(), { now: 10_000, ...options });
    expect(marked(rows)).toEqual({ a1: true, a2: false });
  }
  // Shaped again with nothing new, the reply is the same row: its height and memo stand.
  const once = turnView(source, new Set(), { now: 10_000, working: true });
  const again = turnView(source, new Set(), { now: 10_000, working: true });
  expect(again.find((one) => one.id === "a1")).toBe(once.find((one) => one.id === "a1"));
});

test("the row draws Copy and the reply's age, and the layout reserves its line", () => {
  // Read off the module, so the file runs (and this test fails) where the row does not exist yet.
  const { ReplyActions } = messageActions as { ReplyActions?: (props: { row: AcpmuxRow }) => React.ReactNode };
  expect(ReplyActions).toBeDefined();
  const Actions = ReplyActions!;
  const html = renderToStaticMarkup(<Actions row={reply("a1", 1_000, BEFORE_STEER)} />);
  expect(html).toContain('class="cv-turn-actions cv-reply-actions"');
  expect(html).toContain('aria-label="Copy"');
  expect(html).toContain('class="cv-turn-time"');
  const plain = reply("a1", 1_000, BEFORE_STEER);
  const height = (one: AcpmuxRow) => layoutConversation([one, row("m1", "user", 2_000)], 600).heights[0]!;
  expect(height({ ...plain, replyActions: true }) - height(plain)).toBe(28);
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

// l10n-allow-file: test fixtures (sample review comments), not shipped UI.
// A sent comment stays as a thread: the bridge's `keep` send, the thread card per state, and the
// poll gate (only while a thread is "sent").
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { hasSentThread } from "../diff-viewer/useDiffComments";
import { installPageDiffComments, sendComments } from "./bridge";
import { resolveCommentLabels } from "./labels";
import { SavedComment } from "./SavedComment";
import type { DiffCommentRecord } from "./types";

const labels = resolveCommentLabels(undefined);
const base: DiffCommentRecord = {
  id: "c1",
  filePath: "src/a.ts",
  side: "additions",
  startLine: 3,
  endLine: 3,
  lineText: "",
  message: "Take it from config.",
  createdAt: "2026-11-07T00:00:00.000Z",
  updatedAt: "2026-11-07T00:00:00.000Z",
};
const thread = (state: "sent" | "answered" | "failed", reply?: string): DiffCommentRecord => ({
  ...base,
  thread: {
    promptId: "p1",
    sentAt: "2026-11-07T00:01:00.000Z",
    state,
    ...(reply != null ? { reply: { text: reply, at: "2026-11-07T00:02:00.000Z" } } : {}),
  },
});
const render = (comment: DiffCommentRecord, withReply = true) =>
  renderToStaticMarkup(
    <SavedComment
      comment={comment}
      labels={labels}
      onDelete={() => {}}
      onReply={withReply ? () => {} : undefined}
      onSaveMessage={() => {}}
    />,
  );

afterEach(() => installPageDiffComments(null));

function fakeHost(answer: unknown) {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  installPageDiffComments({
    call: async (_op: string, args: { method: string; params: Record<string, unknown> }) => {
      calls.push(args);
      return answer;
    },
  } as never);
  return calls;
}

test("send without keep sends today's request and reads cleared", async () => {
  const calls = fakeHost({ sent: true, cleared: ["a"] });
  expect(await sendComments("/r", ["a", "b"], { a: "1", b: "2" }, "t", "op")).toEqual(["a"]);
  expect(calls[0]?.params).toEqual({ repoRoot: "/r", ids: ["a", "b"], versions: { a: "1", b: "2" }, text: "t" });
});

test("send with keep says so and reads threaded", async () => {
  const calls = fakeHost({ sent: true, threaded: ["b"] });
  expect(await sendComments("/r", ["a", "b"], {}, "t", "op", true)).toEqual(["b"]);
  expect(calls[0]?.params.keep).toBe(true);
});

test("a plain comment keeps Edit and Delete", () => {
  const html = render(base);
  expect(html).toContain("Edit");
  expect(html).toContain("Delete");
  expect(html).not.toContain("Resolve");
});

test("a sent thread says it was sent and offers Resolve only", () => {
  const html = render(thread("sent"));
  expect(html).toContain("Sent to agent…");
  expect(html).toContain("Resolve");
  expect(html).not.toContain(">Reply<");
});

test("an answered thread shows the reply with Reply and Resolve", () => {
  const html = render(thread("answered", "Done.\nSee config.ts"));
  expect(html).toContain("comment-thread-reply");
  expect(html).toContain("See config.ts");
  expect(html).toContain(">Reply<");
  expect(html).toContain("Resolve");
});

test("a failed thread says the turn failed", () => {
  expect(render(thread("failed"))).toContain("The agent&#x27;s turn failed");
});

test("polling is wanted only while a thread is sent", () => {
  expect(hasSentThread([base, thread("answered", "x"), thread("failed")])).toBe(false);
  expect(hasSentThread([base, thread("sent")])).toBe(true);
});

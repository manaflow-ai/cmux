import { expect, test } from "bun:test";
import { pullRequestActionPrompt } from "./pullRequestActionPrompt";
import type { HeaderPullRequest } from "./headerState";
const pr: HeaderPullRequest = {
  number: 1,
  url: "https://github.com/example/repo/pull/1",
  title: "PR",
  state: "open",
  headSha: "a".repeat(40),
  review: "review_required",
  mergeable: "unknown",
  checks: { state: "failing", passed: 0, total: 1 },
  checkList: [],
};
function fixture() {
  const calls: string[] = [];
  let finish!: (value: unknown) => void;
  const gesture = { promptId: "bound-prompt", ticket: Promise.resolve("bound-ticket") };
  const client = {
    selectedSession: "A",
    selectionToken: 1,
    bindSendGesture: () => {
      calls.push("bind");
      return gesture;
    },
    pullRequestAction: () => {
      calls.push("read");
      return new Promise<unknown>((resolve) => {
        finish = resolve;
      });
    },
  };
  const sent: unknown[] = [];
  const io = {
    currentClient: () => client,
    send: async (params: unknown) => {
      sent.push(params);
    },
    error: () => new Error("changed"),
  };
  return {
    client,
    gesture,
    calls,
    sent,
    io,
    finish: (value: unknown) => finish(value),
    reply: { sessionId: "A", header: pr, prompt: "actual log tail" },
  };
}

test("the click is reserved before log reads and its prompt goes to the same chat", async () => {
  const f = fixture();
  const task = pullRequestActionPrompt(f.client, "A", pr, "fixChecks", new AbortController().signal, f.io);
  expect(f.calls).toEqual(["bind", "read"]);
  expect(f.sent).toEqual([]);
  f.finish(f.reply);
  await task;
  expect(f.sent[0]).toMatchObject({ expectedSessionId: "A", text: "actual log tail", gesture: f.gesture });
});

test("A→B→A and cancelled requests cannot submit their delayed context", async () => {
  for (const change of ["selection", "cancel"] as const) {
    const f = fixture(),
      abort = new AbortController();
    const task = pullRequestActionPrompt(f.client, "A", pr, "addressComments", abort.signal, f.io);
    if (change === "selection") f.client.selectionToken += 2;
    else abort.abort();
    f.finish(f.reply);
    await expect(task).rejects.toThrow("changed");
    expect(f.sent).toEqual([]);
  }
});

test("wrong chat, changed head and absent context refuse the send", async () => {
  for (const reply of [{ sessionId: "B" }, { header: { ...pr, headSha: "b".repeat(40) } }, { prompt: "" }]) {
    const f = fixture();
    const task = pullRequestActionPrompt(f.client, "A", pr, "fixChecks", new AbortController().signal, f.io);
    f.finish({ ...f.reply, ...reply });
    await expect(task).rejects.toThrow("changed");
    expect(f.sent).toEqual([]);
  }
});

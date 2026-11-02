// l10n-allow-file: test fixtures.
// A chat's sub-sessions as the summary card lists them and the transcript's cards read them
// (subsessions.ts), from acpmux's session summaries as the pane cuts them (sessionList.ts).
import { expect, test } from "bun:test";
import { sessionEntry } from "../sessionList";
import { SubsessionStore, subsessionDisplayName, subsessionInfo, subsessionRows, waitingLine } from "./subsessions";
import { translate } from "../i18n";

/// A session summary as acpmux sends it, with the fields the sub-session rows read.
function summary(sessionId: string, fields: Record<string, unknown> = {}) {
  return sessionEntry({
    sessionId,
    name: `claude-sr2/${sessionId}`,
    status: "idle",
    pendingPermissions: 0,
    queued: 0,
    lane: { state: "idle", step: null, title: null, since: null, error: null },
    ...fields,
  });
}

test("a summary's sub-session fields: its parent, short name, lane, queue and what its turn does", () => {
  const entry = summary("tests", {
    startedBy: "chat",
    shortName: "tests",
    effort: "high",
    lastMessage: { role: "agent", text: "Done." },
    queued: 2,
    lane: { state: "working", step: "Run the tests", title: null, since: 1, error: null },
    turn: { planStep: "Check retries", activity: "bun test src/net", prompt: "Run the tests" },
  });
  expect(entry).toMatchObject({
    startedBy: "chat",
    shortName: "tests",
    lane: "working",
    queued: 2,
    doing: "Check retries · bun test src/net",
    effort: "high",
    lastMessage: "Done.",
  });
  expect(subsessionInfo(entry)).toMatchObject({ effort: "high", parent: "chat", lastMessage: "Done." });
  // Without a plan step or a tool, what the turn was asked; not working, nothing.
  expect(summary("a", { lane: { state: "working", step: "Fix the grid" }, turn: {} }).doing).toBe("Fix the grid");
  expect(summary("b", { turn: { activity: "Read" } }).doing).toBeUndefined();
  expect(summary("c", { queued: 0 }).queued).toBeUndefined();
  expect(summary("d", { waitingOn: "question", waitingPrompt: "Which branch?" }).waitingOn).toEqual({
    on: "question",
    prompt: "Which branch?",
  });
  expect(summary("e", { waitingOn: "permission" }).waitingOn).toEqual({ on: "permission" });
  expect(summary("f", { waitingOn: "nothing" }).waitingOn).toBeUndefined();
});

test("an unnamed sub-session gets a localized display name instead of its opaque id", () => {
  const t = translate;
  const session = { name: "optchat-123456789", sessionId: "optchat-123456789" };
  expect(subsessionDisplayName(t, session)).toBe("Subagent");
  expect(subsessionDisplayName(t, { name: "claude/optchat-a1b2c3d4", sessionId: "session-123" })).toBe("Subagent");
  expect(subsessionDisplayName(t, { name: "Review /optchat-logs", sessionId: "session-456" })).toBe(
    "Review /optchat-logs",
  );
  expect(subsessionDisplayName(t, { ...session, name: "Reviewer" })).toBe("Reviewer");
});

test("a sub-session's state: working, needs input, failed (or lost) or done, with its unread mark when done", () => {
  const lane = (state: string) => ({ lane: { state } });
  expect(subsessionInfo(summary("a", { ...lane("working"), shortName: "a", queued: 1 }))).toEqual({
    sessionId: "a",
    name: "a",
    state: "working",
    queued: 1,
  });
  expect(subsessionInfo(summary("b", { ...lane("input"), waitingOn: "permission" }))).toMatchObject({
    state: "input",
    waiting: { on: "permission" },
  });
  expect(subsessionInfo(summary("c", lane("lost"))).state).toBe("failed");
  expect(subsessionInfo(summary("d", { ...lane("failed"), unread: true })).unread).toBeUndefined();
  expect(subsessionInfo(summary("e", { ...lane("idle"), unread: true })).unread).toBe(true);
  // An older acpmux without a lane: its status dot.
  expect(subsessionInfo(summary("f", { lane: null, indicator: "input" })).state).toBe("input");
  // Without a short name, its title (the name acpmux made for it says nothing).
  const titled = summary("g", { name: "claude-2", harness: "claude", title: "Audit the fetch helper" });
  expect(subsessionInfo(titled).name).toBe("Audit the fetch helper");
});

test("the chat's sub-sessions, theirs indented under each, waiting first, then working, then ended", () => {
  const sessions = [
    summary("chat"),
    summary("done-old", { startedBy: "chat", shortName: "old", createdAt: 1 }),
    summary("working", { startedBy: "chat", shortName: "tests", createdAt: 2, lane: { state: "working" } }),
    summary("grandchild", { startedBy: "working", shortName: "fixture", createdAt: 3, lane: { state: "input" } }),
    summary("asking", { startedBy: "chat", shortName: "docs", createdAt: 4, lane: { state: "input" } }),
    summary("done-new", { startedBy: "chat", shortName: "new", createdAt: 5 }),
    summary("archived", { startedBy: "chat", shortName: "gone", tags: { archived: "1" } }),
    summary("other", { startedBy: "another-chat", shortName: "theirs" }),
    // A spawned chat (acpmux new) is a started chat, not a sub-session.
    summary("spawned", { spawnedBy: "chat" }),
  ];
  expect(subsessionRows(sessions, "chat").map((row) => [row.name, row.depth, row.state])).toEqual([
    ["docs", 0, "input"],
    ["tests", 0, "working"],
    ["fixture", 1, "input"],
    ["new", 0, "done"],
    ["old", 0, "done"],
  ]);
  expect(subsessionRows(sessions, undefined)).toEqual([]);
  // A loop in the links draws each once.
  const loop = [summary("x", { startedBy: "y" }), summary("y", { startedBy: "x" })];
  expect(subsessionRows(loop, "x").map((row) => row.sessionId)).toEqual(["y"]);
});

test("what a sub-session waits on the person for, in one line", () => {
  const t = translate;
  expect(waitingLine(t, { on: "permission" })).toBe("Waiting for permission");
  expect(waitingLine(t, { on: "question" })).toBe("Waiting on a question · answer in the app");
  expect(waitingLine(t, { on: "question", prompt: "Which branch?" })).toBe(
    "Waiting on a question · answer in the app · Which branch?",
  );
});

test("the store follows sub-sessions only, and tells its readers only when one's view changes", () => {
  const store = new SubsessionStore();
  let calls = 0;
  store.subscribe(() => (calls += 1));
  const a = summary("a", { shortName: "a", startedBy: "chat" });
  store.set([summary("chat"), a]);
  expect(calls).toBe(1);
  expect(store.get("chat")).toBeUndefined();
  const first = store.get("a");
  // The same entry, or a new one that reads the same, keeps its view and tells no one.
  store.set([a]);
  store.set([summary("a", { shortName: "a", startedBy: "chat", updatedAt: 9 })]);
  expect(calls).toBe(1);
  expect(store.get("a")).toBe(first!);
  store.set([summary("a", { shortName: "a", startedBy: "chat", lane: { state: "working" } })]);
  expect(calls).toBe(2);
  expect(store.get("a")?.state).toBe("working");
  store.set([]);
  expect(calls).toBe(3);
  expect(store.get("a")).toBeUndefined();
});

test("a sender name shared by live chats never chooses the first one arbitrarily", () => {
  const store = new SubsessionStore();
  let changes = 0;
  store.subscribeNames(() => changes++);
  const local = summary("local", { name: "reviewer", shortName: "reviewer" });
  const remote = summary("remote", { name: "gpu/reviewer", shortName: "reviewer", peer: "gpu" });
  store.set([local, remote]);
  expect(store.find("reviewer")).toBeUndefined();
  expect(store.find("gpu/reviewer")).toBe("remote");
  expect(store.has("local")).toBe(true);
  expect(store.has("remote")).toBe(true);
  const before = changes;
  // Merely changing list order cannot make a colliding sender name actionable or
  // notify subscribers: the set of identities and hosts has not changed.
  store.set([remote, local]);
  expect(store.find("reviewer")).toBeUndefined();
  expect(changes).toBe(before);
  // The ambiguous alias becomes actionable when its other live owner leaves.
  store.set([remote]);
  expect(store.find("reviewer")).toBe("remote");
  expect(changes).toBeGreaterThan(before);
});

test("two peer chats with the same bare sender retain distinct qualified names", () => {
  const store = new SubsessionStore();
  store.set([
    summary("gcp-session", { name: "gcp/audit", peer: "gcp" }),
    summary("aws-session", { name: "aws/audit", peer: "aws" }),
  ]);
  expect(store.find("audit")).toBeUndefined();
  expect(store.find("gcp/audit")).toBe("gcp-session");
  expect(store.find("aws/audit")).toBe("aws-session");
  // An archived chat never hides a unique active sender.
  store.set([
    summary("gcp-session", { name: "gcp/audit", peer: "gcp" }),
    summary("aws-session", { name: "aws/audit", peer: "aws", tags: ["archived"] }),
  ]);
  expect(store.find("audit")).toBe("gcp-session");
  // When all matches are archived and ambiguous, a name alone stays unresolved.
  store.set([
    summary("gcp-session", { name: "gcp/audit", peer: "gcp", tags: ["archived"] }),
    summary("aws-session", { name: "aws/audit", peer: "aws", tags: ["archived"] }),
  ]);
  expect(store.find("audit")).toBeUndefined();
});

test("another agent's message finds its sender's chat by name, and that chat's harness", () => {
  const store = new SubsessionStore();
  let notified = 0;
  let renamed = 0;
  store.subscribe(() => notified++);
  store.subscribeNames(() => renamed++);
  store.set([
    summary("old", { name: "coord-deputy", tags: ["archived"], harness: "codex" }),
    summary("deputy", { name: "coord-deputy", harness: "claude" }),
    summary("child", { startedBy: "chat", shortName: "tests", harness: "codex" }),
  ]);
  // A live chat's name before an archived one's; a sub-session by its short name too.
  expect(store.find("coord-deputy")).toBe("deputy");
  expect(store.find(" tests ")).toBe("child");
  expect(store.find("nobody")).toBeUndefined();
  expect(store.harness("deputy")).toBe("claude");
  expect(renamed).toBe(1);
  // Sub-session cards hear of the one sub-session, not of every chat's name.
  expect(notified).toBe(1);
  // The same list again changes nothing.
  store.set([
    summary("old", { name: "coord-deputy", tags: ["archived"], harness: "codex" }),
    summary("deputy", { name: "coord-deputy", harness: "claude" }),
    summary("child", { startedBy: "chat", shortName: "tests", harness: "codex" }),
  ]);
  expect(renamed).toBe(1);
  expect(notified).toBe(1);
  // A chat leaving the list takes its name with it.
  store.set([summary("child", { startedBy: "chat", shortName: "tests", harness: "codex" })]);
  expect(store.find("coord-deputy")).toBeUndefined();
  expect(renamed).toBe(2);
  expect(notified).toBe(1);
});

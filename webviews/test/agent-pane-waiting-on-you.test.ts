// l10n-allow-file: test fixtures (sample asks and chats), not shipped UI.
// Waiting on you (queue/queueModel.ts, queue/historyPages.ts): acpmux's `_acpmux/review_queue`
// read defensively and sorted by score, the keyboard map, the one-click answers each kind takes,
// and answers sent through Needs you's own path (needsYou/useNeedsYou.ts `answerAnotherChat`,
// `answerParams`), never a second one.
import { expect, test } from "bun:test";
import { answerAnotherChat, answerParams } from "../src/agent-session/acpmux/needsYou/useNeedsYou";
import { historyPages, queueKey } from "../src/agent-session/acpmux/queue/historyPages";
import {
  auditEntries,
  isOlderDaemon,
  needsYouItem,
  queueAnswers,
  queueCommand,
  queueReasons,
  readQueue,
  sortQueue,
  verdictParams,
  type QueueItem,
} from "../src/agent-session/acpmux/queue/queueModel";

const options = [
  { optionId: "allow", name: "Allow", kind: "allow_once" },
  { optionId: "always", name: "Always allow", kind: "allow_always" },
  { optionId: "deny", name: "Deny", kind: "reject_once" },
];

function item(over: Partial<QueueItem> = {}): QueueItem {
  return {
    id: "acpmux:p1",
    kind: "approval",
    sessionId: "s1",
    title: "Fix the upload test",
    harness: "claude",
    ask: "Run bun test",
    at: 1_000,
    impact: 1,
    impactReasons: [],
    score: 1,
    options,
    permissionId: "p1",
    ...over,
  };
}

test("a read keeps whole items only and sorts them by score, then the oldest ask", () => {
  const reply = readQueue({
    now: 10_000,
    peersOmitted: ["studio", { name: "laptop" }, 3],
    items: [
      { id: "acpmux:a", kind: "approval", sessionId: "s1", title: "A", ask: "a", at: 5_000, score: 2, options },
      { id: "acpmux:b", kind: "question", sessionId: "s2", title: "B", ask: "b", ageMs: 9_000, score: 2 },
      { id: "acpmux:c", kind: "plan", sessionId: "s3", title: "C", ask: "c", at: 9_000, score: 7, host: "studio" },
      {
        id: "pr:https://example.com/pull/1",
        kind: "pr",
        title: "PR",
        ask: "Review",
        at: 1,
        score: 1,
        prUrl: "https://example.com/pull/1",
      },
      // Not shown: no id, an unknown kind, no chat for an ask.
      { kind: "approval", sessionId: "s4", score: 9 },
      { id: "x", kind: "mystery", sessionId: "s5", score: 9 },
      { id: "y", kind: "approval", score: 9 },
      "nonsense",
    ],
  });
  expect(reply.items.map((each) => each.id)).toEqual([
    // Another machine's row and a pull request's are told apart by machine and chat.
    "acpmux:c@studio/s3",
    // Equal scores: the one asked first (b at now - ageMs = 1_000) before a (5_000).
    "acpmux:b",
    "acpmux:a",
    "pr:https://example.com/pull/1@/",
  ]);
  expect(reply.items[1]!.at).toBe(1_000);
  expect(reply.items[0]!.host).toBe("studio");
  expect(reply.peersOmitted).toEqual(["studio", "laptop"]);
  expect(reply.now).toBe(10_000);
  expect(readQueue(undefined, 5).items).toEqual([]);
});

test("the order never shuffles between reads of the same items", () => {
  const items = [item({ id: "b", score: 1, at: 1 }), item({ id: "a", score: 1, at: 1 }), item({ id: "c", score: 3 })];
  expect(sortQueue(items).map((each) => each.id)).toEqual(["c", "a", "b"]);
  expect(sortQueue([...items].reverse()).map((each) => each.id)).toEqual(["c", "a", "b"]);
});

test("the keyboard map: j/k and the arrows move, Return opens, x exports; no plain key answers", () => {
  expect(queueCommand({ key: "j" })).toEqual({ kind: "move", step: 1 });
  expect(queueCommand({ key: "ArrowDown" })).toEqual({ kind: "move", step: 1 });
  expect(queueCommand({ key: "k" })).toEqual({ kind: "move", step: -1 });
  expect(queueCommand({ key: "ArrowUp" })).toEqual({ kind: "move", step: -1 });
  expect(queueCommand({ key: "Enter" })).toEqual({ kind: "open" });
  // A permission answer needs the person's click or the app's shortcut, never a letter the page saw.
  expect(queueCommand({ key: "a" })).toBeUndefined();
  expect(queueCommand({ key: "d" })).toBeUndefined();
  expect(queueCommand({ key: "1" })).toBeUndefined();
  expect(queueCommand({ key: "x" })).toEqual({ kind: "export" });
  expect(queueCommand({ key: "e" })).toEqual({ kind: "export" });
  // A chord is the app's, and other keys do nothing.
  expect(queueCommand({ key: "a", metaKey: true })).toBeUndefined();
  expect(queueCommand({ key: "j", ctrlKey: true })).toBeUndefined();
  expect(queueCommand({ key: "A", shiftKey: true })).toBeUndefined();
  expect(queueCommand({ key: "0" })).toBeUndefined();
  expect(queueCommand({ key: "z" })).toBeUndefined();
});

test("an approval answers allow once and deny once, never the lasting allow", () => {
  expect(queueAnswers(item())).toEqual([
    { id: "allow", label: "Allow", tone: "allow" },
    { id: "deny", label: "Deny", tone: "deny" },
  ]);
  // A plan approval's options are the agent's own words.
  const plan = item({
    kind: "plan",
    options: [
      { optionId: "go", name: "Approve plan", kind: "allow_once" },
      { optionId: "stay", name: "Keep planning", kind: "reject_once" },
    ],
  });
  expect(queueAnswers(plan).map((each) => [each.id, each.tone])).toEqual([
    ["go", "allow"],
    ["stay", "deny"],
  ]);
});

test("a one-pick question takes its choices here; another machine's ask and a pull request take no one-click answer", async () => {
  // The host answers another chat's question as its card would (homeInboxModel.ts `replyElsewhere`;
  // Leo, 2026-11-10: "this is unusable to respond to i necessarily have to open... this is bad ui").
  const fs = await import("node:fs");
  const record = JSON.parse(
    fs.readFileSync(
      new URL(
        "../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-single.request.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  expect(
    queueAnswers(item({ kind: "question", question: record.request, permissionId: record.permissionId })).map(
      (answer) => [answer.label, answer.tone],
    ),
  ).toEqual([
    ["OAuth 2.0", "choice"],
    ["API keys", "choice"],
    ["Passkeys", "choice"],
  ]);
  // A question whose ask can't be read here has none: its chat's card takes it.
  const question = item({
    kind: "question",
    options: [
      { optionId: "one", name: "Use the cache" },
      { optionId: "two", name: "Skip it" },
    ],
  });
  expect(queueAnswers(question)).toEqual([]);
  expect(queueAnswers(item({ kind: "question" }))).toEqual([]);
  expect(queueAnswers(item({ host: "studio" }))).toEqual([]);
  expect(queueAnswers(item({ kind: "pr", prUrl: "https://example.com/pull/1" }))).toEqual([]);
});

test("an answer goes the way Needs you sends it: the same `chat.permission` params", () => {
  const ask = needsYouItem(item());
  expect(ask.sessionId).toBe("s1");
  expect(ask.permissionId).toBe("p1");
  expect(answerParams(ask, { id: "allow", label: "Allow", tone: "allow" })).toEqual({
    method: "chat.permission",
    params: { sessionId: "s1", permissionId: "p1", optionId: "allow" },
  });
});

test("another chat's approval is answered by the host on the click; a peer's opens instead", async () => {
  const calls: [string, unknown][] = [];
  const call = async <T>(method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    return undefined as T;
  };
  const opened: string[] = [];
  const allow = { id: "allow", label: "Allow", tone: "allow" as const };
  const local = await answerAnotherChat(call, needsYouItem(item()), allow, {
    peer: false,
    open: () => opened.push("s1"),
  });
  expect(local).toBe("answered");
  expect(calls).toEqual([["chat.asks.answer", { sessionId: "s1", permissionId: "p1", optionId: "allow" }]]);
  expect(opened).toEqual([]);

  const peer = await answerAnotherChat(call, needsYouItem(item({ host: "studio" })), allow, {
    peer: true,
    open: () => opened.push("peer"),
  });
  expect(peer).toBe("opened");
  expect(calls.length).toBe(1);
  expect(opened).toEqual(["peer"]);

  // An item with no permission is no answer at all: a refusal, never a stuck row.
  await expect(
    answerAnotherChat(call, needsYouItem(item({ permissionId: undefined })), allow, { peer: false, open: () => {} }),
  ).rejects.toThrow("unanswerable");
});

test("why an item ranks high, in words the page can say; unknown reasons are left out", () => {
  expect(
    queueReasons(
      item({
        impactReasons: [
          "blocksTurn",
          "queuedPrompts:3",
          "costUsd:4.5",
          "subsessions:0",
          "age",
          "mystery:2",
          "queuedPrompts:x",
        ],
      }),
    ),
  ).toEqual([{ kind: "blocksTurn" }, { kind: "queuedPrompts", n: 3 }, { kind: "costUsd", usd: 4.5 }, { kind: "age" }]);
});

test("a pull request's verdict names the PR and its chat; other kinds and other machines' send none", () => {
  const pr = item({ id: "pr:u", kind: "pr", prUrl: "https://example.com/pull/7", permissionId: undefined });
  expect(verdictParams(pr, "accept")).toEqual({
    prUrl: "https://example.com/pull/7",
    sessionId: "s1",
    verdict: "accepted",
  });
  expect(verdictParams(pr, "changes", "  Split the commit  ")).toEqual({
    prUrl: "https://example.com/pull/7",
    sessionId: "s1",
    verdict: "changes",
    comment: "Split the commit",
  });
  expect(verdictParams(item(), "accept")).toBeUndefined();
  // acpmux records a verdict on this Mac only, for a chat it has.
  expect(verdictParams({ ...pr, host: "studio" }, "accept")).toBeUndefined();
  expect(verdictParams({ ...pr, sessionId: "" }, "accept")).toBeUndefined();
});

test("an older acpmux, or a host whose relay does not list the method, reads as older", () => {
  expect(isOlderDaemon({ code: -32601, message: "Method not found" })).toBe(true);
  expect(isOlderDaemon({ code: "-32601" })).toBe(true);
  expect(isOlderDaemon({ code: "transport.method_refused" })).toBe(true);
  expect(isOlderDaemon(new Error("method not found: _acpmux/review_queue"))).toBe(true);
  expect(isOlderDaemon(new Error("socket closed"))).toBe(false);
  expect(isOlderDaemon(undefined)).toBe(false);
});

test("the audit export follows its cursor, and stops at its page cap", async () => {
  const pages: Record<string, { entries: unknown[]; next?: number }> = {
    "": { entries: [{ seq: 1 }, { seq: 2 }], next: 2 },
    "2": { entries: [{ seq: 3 }], next: 3 },
    "3": { entries: [{ seq: 4 }] },
  };
  const asked: unknown[] = [];
  const read = async (params: Record<string, unknown>) => {
    asked.push(params);
    return pages[String(params.cursor ?? "")];
  };
  expect(await auditEntries(read, 10)).toEqual([{ seq: 1 }, { seq: 2 }, { seq: 3 }, { seq: 4 }]);
  // The cursor is acpmux's `seq`, sent back as the number it is.
  expect(asked).toEqual([{}, { cursor: 2 }, { cursor: 3 }]);
  expect(await auditEntries(read, 2)).toEqual([{ seq: 1 }, { seq: 2 }, { seq: 3 }]);
});

test("the queue reads again when an ask or a pull request changes on any machine, and not otherwise", () => {
  const ask = (permissionId: string) => ({
    sessionId: "s1",
    at: 1,
    permission: { permissionId, pending: true, options: [] },
  });
  expect(queueKey([ask("p1"), ask("p2")])).toBe("p1,p2");
  expect(queueKey([ask("p1")])).not.toBe(queueKey([ask("p1"), ask("p2")]));
  expect(queueKey([])).toBe("");
  // A chat with nothing waiting adds nothing, so its other changes never read the queue again.
  const quiet = { sessionId: "q", title: "Quiet", status: "idle" };
  expect(queueKey([], [quiet])).toBe("");
  expect(queueKey([], [{ ...quiet, title: "Renamed" }])).toBe("");
  // Another machine's ask: its chat's count and its waiting state.
  const peer = { sessionId: "studio/s2", peer: "studio" };
  const asking = queueKey([], [{ ...peer, pendingPermissions: 1, indicator: "input" as const }]);
  expect(asking).not.toBe(queueKey([], [peer]));
  expect(queueKey([], [{ ...peer, pendingPermissions: 2, indicator: "input" as const }])).not.toBe(asking);
  // A pull request that opens, turns ready for review or merges.
  const open = { number: 7, title: "Fix", state: "open" as const };
  const withPr = queueKey([], [{ ...peer, pullRequest: open }]);
  expect(withPr).not.toBe(queueKey([], [peer]));
  expect(queueKey([], [{ ...peer, pullRequest: { ...open, reviewReady: true } }])).not.toBe(withPr);
  expect(queueKey([], [{ ...peer, pullRequest: { ...open, state: "merged" as const } }])).not.toBe(withPr);
  expect(queueKey([], [{ ...peer, pullRequestUrls: ["https://example.com/pull/8"] }])).not.toBe(queueKey([], [peer]));
});

test("History opens a chat in its own tab (`chat.select`); another machine's pull request is refused and stays", async () => {
  const natives: string[] = [];
  const selected: string[] = [];
  const verdicts: unknown[] = [];
  const client = {
    ledger: async () => ({}),
    teamAudit: async () => ({}),
    reviewQueue: async () => ({}),
    reviewVerdict: async (params: Record<string, unknown>) => verdicts.push(params),
    audit: async () => ({ entries: [] }),
  };
  const pages = historyPages({
    client: () => client,
    callNative: async <T>(method: string) => {
      natives.push(method);
      return undefined as T;
    },
    selectSession: (sessionId) => selected.push(sessionId),
    asks: [],
  });
  // Needs you's `chat.asks.open` opens nothing from a New Tab page: Return and a row's click show the
  // chat where History's own rows show one.
  pages.queue.open(item());
  pages.ledger.openSession("s9");
  expect(selected).toEqual(["s1", "s9"]);
  expect(natives).toEqual([]);
  // Another machine's chat opens as the sidebar opens it: its listed row, else its qualified id.
  pages.queue.open(item({ host: "studio" }));
  expect(selected).toEqual(["s1", "s9", "studio/s1"]);
  const listed = historyPages({
    client: () => client,
    callNative: async <T>() => undefined as T,
    selectSession: (sessionId) => selected.push(sessionId),
    asks: [],
    sessions: [
      { sessionId: "peer-s1", peer: "studio" },
      { sessionId: "s1", peer: "studio" },
    ],
  });
  listed.queue.open(item({ host: "studio" }));
  expect(selected.at(-1)).toBe("s1");
  const pr = item({ kind: "pr", prUrl: "https://example.com/pull/1" });
  await expect(pages.queue.verdict({ ...pr, host: "studio" }, "accept")).rejects.toThrow();
  expect(verdicts).toEqual([]);
  await pages.queue.verdict(pr, "accept");
  expect(verdicts).toEqual([{ prUrl: "https://example.com/pull/1", sessionId: "s1", verdict: "accepted" }]);
});

test("Export audit fails when neither clipboard path copies, rather than saying it copied", async () => {
  let copies = false;
  const copied: string[] = [];
  const pages = historyPages({
    client: () => ({
      ledger: async () => ({}),
      teamAudit: async () => ({}),
      reviewQueue: async () => ({}),
      reviewVerdict: async () => ({}),
      audit: async () => ({ entries: [{ seq: 1 }] }),
    }),
    callNative: async <T>() => undefined as T,
    selectSession: () => {},
    asks: [],
    copy: async (text) => {
      copied.push(text);
      return copies;
    },
  });
  await expect(pages.queue.exportAudit()).rejects.toThrow();
  copies = true;
  expect(await pages.queue.exportAudit()).toBe(1);
  expect(JSON.parse(copied.at(-1) ?? "")).toEqual([{ seq: 1 }]);
});

test("a row that entered late still collapses when answered: the entrance never outlasts its run", async () => {
  const css = await Bun.file(new URL("../src/agent-session/acpmux/queue/queue.css", import.meta.url)).text();
  const rule = css.split("\n").find((line) => line.includes("animation:wq-enter")) ?? "";
  // A `forwards`/`both` fill would keep the entrance's last frame (1fr, opaque) over [data-leaving].
  expect(rule).toContain(":not([data-leaving])");
  expect(rule).not.toMatch(/\b(both|forwards)\b/);
});

test("an approval with only a lasting allow, or a near-match kind, takes no one-click answer", () => {
  // The one-click answers are exactly allow once and reject once: anything else is the chat's.
  expect(queueAnswers(item({ options: [{ optionId: "always", name: "Always allow", kind: "allow_always" }] }))).toEqual(
    [],
  );
  expect(
    queueAnswers(
      item({
        options: [
          { optionId: "a", name: "Allow", kind: "allow" },
          { optionId: "d", name: "Deny", kind: "reject_always" },
        ],
      }),
    ),
  ).toEqual([]);
});

test("the queue also reads again when what a chat waits on, its status or its pull request's title or checks change", () => {
  const chat = { sessionId: "s4" };
  const waiting = queueKey([], [{ ...chat, waitingOn: { on: "review" } } as never]);
  expect(waiting).not.toBe(queueKey([], [chat]));
  expect(queueKey([], [{ ...chat, waitingOn: { on: "input" } } as never])).not.toBe(waiting);
  expect(queueKey([], [{ ...chat, status: "waiting" }])).not.toBe(queueKey([], [chat]));
  const open = { number: 7, title: "Fix", state: "open" as const };
  const withPr = queueKey([], [{ ...chat, pullRequest: open }]);
  expect(queueKey([], [{ ...chat, pullRequest: { ...open, title: "Fix the upload" } }])).not.toBe(withPr);
  expect(queueKey([], [{ ...chat, pullRequest: { ...open, checks: "failing" } } as never])).not.toBe(withPr);
  const one = queueKey([], [{ ...chat, pullRequestUrls: ["https://example.com/pull/1"] }]);
  expect(
    queueKey([], [{ ...chat, pullRequestUrls: ["https://example.com/pull/1", "https://example.com/pull/2"] }]),
  ).not.toBe(one);
});

test("the queue's total is acpmux's count before its limit, never fewer than the rows it sent", () => {
  const raw = { items: [item()], now: 10 };
  expect(readQueue({ ...raw, total: 250 }).total).toBe(250);
  expect(readQueue(raw).total).toBe(1);
  expect(readQueue({ ...raw, total: 0 }).total).toBe(1);
  expect(readQueue({ ...raw, total: "many" }).total).toBe(1);
});

test("a Request changes comment an older acpmux dropped opens the chat to say it there", async () => {
  const selected: string[] = [];
  let reply: unknown = {};
  const pages = historyPages({
    client: () => ({
      ledger: async () => ({}),
      teamAudit: async () => ({}),
      reviewQueue: async () => ({}),
      reviewVerdict: async () => reply,
      audit: async () => ({ entries: [] }),
    }),
    callNative: async <T>() => undefined as T,
    selectSession: (sessionId) => selected.push(sessionId),
    asks: [],
    copy: async () => true,
  });
  const pr = item({ kind: "pr", prUrl: "https://example.com/pull/1" });
  await pages.queue.verdict(pr, "changes", "Split the commit");
  expect(selected).toEqual(["s1"]);
  // A daemon that delivered it leaves the page where it is; so does a verdict with no words.
  reply = { commentDelivered: true };
  await pages.queue.verdict(pr, "changes", "Split the commit");
  reply = {};
  await pages.queue.verdict(pr, "changes");
  expect(selected).toEqual(["s1"]);
});

test("a dropped comment the clipboard also refused keeps the page open: its notice holds the words", async () => {
  const selected: string[] = [];
  const pages = historyPages({
    client: () => ({
      ledger: async () => ({}),
      teamAudit: async () => ({}),
      reviewQueue: async () => ({}),
      reviewVerdict: async () => ({}),
      audit: async () => ({ entries: [] }),
    }),
    callNative: async <T>() => undefined as T,
    selectSession: (sessionId) => selected.push(sessionId),
    asks: [],
    copy: async () => false,
  });
  const pr = item({ kind: "pr", prUrl: "https://example.com/pull/1" });
  const reply = await pages.queue.verdict(pr, "changes", "Split the commit");
  expect(reply).toMatchObject({ commentCopied: false });
  expect(selected).toEqual([]);
});

test("the queue reads again when a listed chat is renamed", () => {
  const chat = { sessionId: "s4", status: "waiting" as const, title: "Before" };
  expect(queueKey([], [{ ...chat, title: "After" }])).not.toBe(queueKey([], [chat]));
  expect(queueKey([], [{ ...chat, name: "worker" }])).not.toBe(queueKey([], [chat]));
});

test("one pull request listed in two chats is two rows, each answered on its own, with ids that never move", () => {
  const pr = { id: "pr:https://example.com/pull/1", kind: "pr", prUrl: "https://example.com/pull/1", at: 1 };
  const reply = readQueue({
    items: [
      { ...pr, sessionId: "s1" },
      { ...pr, sessionId: "s2", host: "studio" },
      { id: "acpmux:p1", kind: "approval", sessionId: "s3", at: 2 },
    ],
    now: 10,
  });
  const ids = reply.items.map((each) => each.id);
  expect(new Set(ids).size).toBe(3);
  expect(ids).toContain("pr:https://example.com/pull/1@/s1");
  expect(ids).toContain("pr:https://example.com/pull/1@studio/s2");
  // This Mac's ask keeps acpmux's id.
  expect(ids).toContain("acpmux:p1");
  // A row's id does not hang on the others: alone, the same pull request has the same id.
  const alone = readQueue({ items: [{ ...pr, sessionId: "s1" }], now: 10 });
  expect(alone.items[0]!.id).toBe("pr:https://example.com/pull/1@/s1");
});

test("a pull request's chat finishing its turn reads the queue again", () => {
  // acpmux leaves a pull request out while its chat runs, so the end of the turn must read again.
  const chat = { sessionId: "s5", pullRequest: { number: 3, title: "Fix", state: "open" as const } };
  expect(queueKey([], [{ ...chat, status: "idle" }])).not.toBe(queueKey([], [{ ...chat, status: "running" }]));
  const urls = { sessionId: "s6", pullRequestUrls: ["https://example.com/pull/3"] };
  expect(queueKey([], [{ ...urls, status: "idle" }])).not.toBe(queueKey([], [{ ...urls, status: "running" }]));
});

test("a comment the chat did not get goes to the clipboard, and the chat opens to paste it", async () => {
  const selected: string[] = [];
  const copied: string[] = [];
  let copies = true;
  const pages = historyPages({
    client: () => ({
      ledger: async () => ({}),
      teamAudit: async () => ({}),
      reviewQueue: async () => ({}),
      reviewVerdict: async () => ({ recorded: true }),
      audit: async () => ({ entries: [] }),
    }),
    callNative: async <T>() => undefined as T,
    selectSession: (sessionId) => selected.push(sessionId),
    asks: [],
    copy: async (text) => {
      copied.push(text);
      return copies;
    },
  });
  const pr = item({ kind: "pr", prUrl: "https://example.com/pull/1" });
  expect(await pages.queue.verdict(pr, "changes", "Split the commit")).toMatchObject({ commentCopied: true });
  expect(copied).toEqual(["Split the commit"]);
  expect(selected).toEqual(["s1"]);
  copies = false;
  expect(await pages.queue.verdict(pr, "changes", "Split it")).toMatchObject({ commentCopied: false });
});

test("a refused comment comes back in its box, or beside a newer one being written, never over it", async () => {
  const { createComments } = await import("../src/agent-session/acpmux/queue/comments");
  const comments = createComments();
  comments.restore({ id: "a", text: "Split the commit" });
  expect(comments.get().draft).toEqual({ id: "a", text: "Split the commit" });
  // Another row's comment is being written when the first is refused: both stay.
  comments.setDraft({ id: "b", text: "Rename it" });
  comments.restore({ id: "a", text: "Split the commit" });
  expect(comments.get().draft).toEqual({ id: "b", text: "Rename it" });
  expect(comments.get().unsent).toBe("Split the commit");
  // An empty box gives way.
  comments.dismissUnsent();
  comments.setDraft({ id: "b", text: "  " });
  comments.restore({ id: "a", text: "Split the commit" });
  expect(comments.get().draft).toEqual({ id: "a", text: "Split the commit" });
  expect(comments.get().unsent).toBeUndefined();
  // Kept words add up and outlive any one page.
  comments.keepUnsent("one");
  comments.keepUnsent("two");
  expect(comments.get().unsent).toBe("one\n\ntwo");
});

test("a read asked before the key moved does not count as current once it lands", async () => {
  const { createQueueCache } = await import("../src/agent-session/acpmux/queue/useQueue");
  const cache = createQueueCache();
  cache.note("a");
  const asked = cache.generation();
  cache.note("b");
  cache.note("a");
  expect(cache.generation()).not.toBe(asked);
});

test("opening or answering one row never drops the words typed in another's comment box", async () => {
  const { createComments } = await import("../src/agent-session/acpmux/queue/comments");
  const comments = createComments();
  comments.open("a");
  comments.setDraft({ id: "a", text: "Split the commit" });
  // Request changes again on the same row keeps what is typed.
  comments.open("a");
  expect(comments.get().draft).toEqual({ id: "a", text: "Split the commit" });
  // Accepting another row leaves this box alone.
  comments.close("b");
  expect(comments.get().draft).toEqual({ id: "a", text: "Split the commit" });
  // Opening another row's box keeps the words beside it.
  comments.open("b");
  expect(comments.get().draft).toEqual({ id: "b", text: "" });
  expect(comments.get().unsent).toBe("Split the commit");
  // Its own send closes it.
  comments.close("b");
  expect(comments.get().draft).toBeUndefined();
});

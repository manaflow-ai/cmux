// l10n-allow-file: test fixtures.
// Automated notices older senders put in a prompt as plain text (agentNotice.ts
// AUTOMATED_NOTICE_HEADS): the stall reconciler's conflict notice and spend guard, Claude Code's Stop
// hook feedback, and acpmux's inbox notice read back from a Claude session's history. Each draws as
// a notice's line that opens to its whole text, never the person's bubble and never hidden; the
// person's own prompt in the pane is never read for them.
import { expect, test } from "bun:test";
import { AUTOMATED_NOTICE_HEADS, automatedNotice, noticeRowText } from "./agentNotice";
import { incomingPrompt } from "./incomingMessage";
import { projectInboxRows } from "./laneNoticeBatches";
import { laneNotice } from "./laneReport";
import type { AcpmuxRow } from "../model";

const CONFLICT =
  "[stall-reconciler] #31356 conflicts with main at 42ed8159e6c1: .github/workflows/cloud-capture-provision.yml, webviews/src/agent-session/acpmux/direct.ts. Rebase or merge base; this notice won't repeat for head 3dc49e20c151.";
const SPEND =
  "Spend guard (stall reconciler): this session shows $212 in 24h (thresholds: $150/day, 40 subagents/day; machines/spend-guard.json). Rulebook, tools/supervisor-models.json: pick each subagent's model by task kind. No reply needed; this is sent once a day.";
const HOOK = "Stop hook feedback:\n[~/.claude/hooks/check.sh]: 2 tests still fail in webviews/test/x.test.ts.\nFix them before stopping.";
const INBOX =
  "[inbox] New messages from other agents in 2 threads.\n- claude-sr2 (thread t-1): merged #31356\n- coord-deputy (thread t-2): please rebase";

const outbox = { client: "acpmux-outbox#01a16e@lane-box-2" };
const cli = { client: "acpmux-cli#01a2f3@lane-box-2" };
const adopted = { client: "adopt" };
const watched = { client: "watch" };

test("every declared head reads its sender, a one-sentence title and the rest as the body", () => {
  expect(automatedNotice(CONFLICT)).toEqual({
    notice: {
      sender: "stall-reconciler",
      severity: "info",
      title:
        "#31356 conflicts with main at 42ed8159e6c1: .github/workflows/cloud-capture-provision.yml, webviews/src/agent-session/acpmux/direct.ts",
      links: [],
    },
    body: "Rebase or merge base; this notice won't repeat for head 3dc49e20c151.",
  });
  const spend = automatedNotice(SPEND)!;
  expect(spend.notice.sender).toBe("spend-guard");
  expect(spend.notice.title).toBe(
    "this session shows $212 in 24h (thresholds: $150/day, 40 subagents/day; machines/spend-guard.json)",
  );
  expect(spend.body).toStartWith("Rulebook, tools/supervisor-models.json");
  const hook = automatedNotice(HOOK)!;
  expect(hook.notice.sender).toBe("hook");
  expect(hook.notice.title).toBe("[~/.claude/hooks/check.sh]: 2 tests still fail in webviews/test/x.test.ts");
  expect(hook.body).toBe("Fix them before stopping.");
  // The list is small and declared: each head has a sender and is anchored at the start.
  for (const { sender, head } of AUTOMATED_NOTICE_HEADS) {
    expect(sender).toMatch(/^[a-z][a-z-]*$/);
    expect(head.source.startsWith("^")).toBe(true);
  }
});

test("no word is lost: the row's text holds the whole notice for Find, Copy and export", () => {
  for (const text of [CONFLICT, SPEND, HOOK]) {
    const read = automatedNotice(text)!;
    const row = noticeRowText(read.notice, read.body).replace(/\s+/g, " ");
    const words = text
      .replace(/^(\[stall-reconciler\]|Spend guard \(stall reconciler\):|Stop hook feedback:)/, "")
      .replace(/\s+/g, " ")
      .trim();
    // The title drops the sentence's period; every other character is kept in order.
    expect(row.replace(/[.!?]/g, "")).toBe(words.replace(/[.!?]/g, ""));
  }
  // A first line too long for a title is cut on the line, and the body keeps all of it.
  const long = `[stall-reconciler] ${"conflicts in a.ts, ".repeat(20)}and more`;
  const read = automatedNotice(long)!;
  expect(read.notice.title.length).toBeLessThanOrEqual(200);
  expect(read.notice.title.endsWith("…")).toBe(true);
  expect(read.body).toBe(long.slice("[stall-reconciler] ".length));
});

test("text with no declared head, or a head alone, is no automated notice", () => {
  expect(automatedNotice("Rebase #31356 on main please.")).toBeUndefined();
  expect(automatedNotice("[stall-reconciler]")).toBeUndefined();
  expect(automatedNotice("see [stall-reconciler] #1 conflicts")).toBeUndefined();
  expect(automatedNotice("Stop hook feedback")).toBeUndefined();
});

test("from acpmux send at a shell or its outbox, each draws as a notice's line, not the person's bubble", () => {
  for (const msg of [outbox, cli]) {
    for (const [text, sender] of [
      [CONFLICT, "stall-reconciler"],
      [SPEND, "spend-guard"],
      [HOOK, "hook"],
    ] as const) {
      const incoming = incomingPrompt(text, msg);
      expect(incoming?.kind).toBe("message");
      if (incoming?.kind !== "message") continue;
      expect(incoming.message.name).toBe(sender);
      expect(incoming.message.notice?.severity).toBe("info");
      expect(incoming.message.raw).toBe(text);
    }
  }
});

test("in an adopted or watched Claude session's history, each draws as a notice's line too", () => {
  for (const msg of [adopted, watched]) {
    const incoming = incomingPrompt(`<system-reminder>context</system-reminder>\n${CONFLICT}`, msg);
    expect(incoming?.kind).toBe("message");
    if (incoming?.kind === "message") expect(incoming.message.notice?.sender).toBe("stall-reconciler");
    const hook = incomingPrompt(HOOK, msg);
    expect(hook?.kind === "message" && hook.message.notice?.sender).toBe("hook");
    // acpmux's inbox notice, which the history keeps no provenance for: the inbox's notice line, its
    // text whole behind the chevron, never parsed into thread rows (a topic with spaces parsed into
    // none, and the message drew nothing: router-review on cmux#34320).
    const spaced = "[inbox] New messages from other agents in 1 thread.\n- lane-a (thread topic:picker plan): done";
    for (const text of [INBOX, spaced]) {
      const inbox = incomingPrompt(text, msg);
      expect(inbox?.kind).toBe("message");
      if (inbox?.kind !== "message") continue;
      expect(inbox.message.name).toBe("inbox");
      expect(inbox.message.notice?.title).toStartWith("New messages from other agents in ");
      expect(noticeRowText(inbox.message.notice!, inbox.message.text)).toContain(text.split("\n")[1]!);
    }
    // From a shell it stays the inbox line laneReport.ts draws, as on base.
    expect(incomingPrompt(INBOX, cli)).toMatchObject({ kind: "message", message: { name: "inbox" } });
  }
});

test("the person's own prompt in the pane is never read as an automated notice", () => {
  for (const text of [CONFLICT, SPEND, HOOK, INBOX]) {
    expect(incomingPrompt(text, undefined)).toBeUndefined();
    expect(incomingPrompt(text, { client: "app" })).toBeUndefined();
    expect(incomingPrompt(text, { client: "web#01a" })).toBeUndefined();
  }
});

/// A row as direct.ts draws an incoming prompt, for the inbox projection.
function received(id: string, text: string, msg: { client: string }): AcpmuxRow {
  const incoming = incomingPrompt(text, msg)!;
  const message = incoming.kind === "message" ? incoming.message : undefined;
  return { id, version: 1, at: 1, kind: "user", text: message?.text ?? text, untyped: true, incoming } as AcpmuxRow;
}

test("an inbox notice whose thread topic holds spaces keeps its rows through the projection", () => {
  const spaced =
    "[inbox] New messages from other agents in 1 thread.\n- 1 new in picker plan from lane-a: done with the picker (thread topic:picker plan)";
  const message = { name: "inbox", text: spaced.slice("[inbox] ".length), raw: spaced };
  expect(laneNotice(message)?.threads?.map((thread) => thread.id)).toEqual(["topic:picker plan"]);
  const rows = projectInboxRows([received("a", spaced, cli)]);
  expect(rows.length).toBe(1);
  expect(rows[0]!.text).toContain("done with the picker");
});

test("an inbox notice that names no thread this page can read keeps its own row, its text whole", () => {
  const odd = "[inbox] New messages from other agents in 2 threads.\nSomething this page has no parser for.";
  const row = received("b", odd, cli);
  const rows = projectInboxRows([row]);
  expect(rows).toEqual([row]);
  expect(rows[0]!.incoming?.kind === "message" && rows[0]!.incoming.message.raw).toBe(odd);
});

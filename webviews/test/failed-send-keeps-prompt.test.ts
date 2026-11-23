// l10n-allow-file: test fixture prompts, not shipped UI.
// A send that fails never loses what was typed: its words and attachments end in exactly one place,
// the chat's failed row (with Retry and Edit) or back in the composer, and a Retry goes under the
// first try's prompt id, so acpmux (which runs a prompt id once, hub/prompt_ledger.rs) never runs one
// submit twice. A draft typed while acpmux cannot take it is kept per chat, and its newest text
// lands once acpmux answers again. Stressed with random text and attachments over every failure
// the pane meets: a prompt RPC error, a refusal, a chat that is gone, and the connection dropping.
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import {
  draftHistory,
  hydratedDraft,
  markDraftRead,
  noteDraftEdited,
  readPersistedDraft,
  settlePendingDraftWrites,
  writePersistedDraft,
} from "../src/agent-session/acpmux/composerDraft";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { teardownDom } from "./support/domTeardown";

const CHAT = "0190a000-0000-7000-8000-0000000000f5";

type Outcome = "ok" | "rpc" | "refused" | "gone" | "drop";
const FAILURES: Outcome[] = ["rpc", "refused", "gone", "drop"];

/// A daemon with one idle chat. Each `session/prompt` takes the next outcome from `plan`
/// ("ok" once it runs out); every prompt id it ran is in `ran`.
function fakeDaemon(plan: Outcome[], ran: string[]) {
  const session = {
    sessionId: CHAT,
    cwd: "/Users/you/src/app",
    title: "app",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: Date.UTC(2026, 10, 14, 10, 0, 0),
  };
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: {
            acpmux: { origin: "local", extensions: [], operations: [] },
          },
        };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      case "session/prompt":
        return { stopReason: "end_turn" };
      default:
        return null;
    }
  };
  return () => {
    let socket: any;
    const reply = (id: unknown, body: Record<string, unknown>) =>
      queueMicrotask(() =>
        socket.onmessage?.({
          data: JSON.stringify({ jsonrpc: "2.0", id, ...body }),
        }),
      );
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        if (message.method === "session/prompt") {
          const promptId = message.params?._meta?.acpmux?.promptId as string;
          const outcome = plan.shift() ?? "ok";
          if (outcome === "ok") ran.push(promptId);
          else if (outcome === "rpc")
            return reply(message.id, {
              error: { code: -32603, message: "internal error" },
            });
          else if (outcome === "refused")
            return reply(message.id, {
              error: {
                code: -32000,
                message: "transport.refused",
                data: { code: "transport.refused", origin: "native" },
              },
            });
          else if (outcome === "gone")
            return reply(message.id, {
              error: { code: -32602, message: `session ${CHAT} not found` },
            });
          else {
            // acpmux restarts as the prompt reaches it, before it took it.
            socket.readyState = 3;
            queueMicrotask(() => socket.onclose?.({ code: 1012 }));
            return;
          }
        }
        reply(message.id, { result: answer(message.method) });
      },
      close() {
        socket.readyState = 3;
      },
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

async function connect(plan: Outcome[], ran: string[]) {
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: CHAT,
    },
    () => undefined,
    undefined,
    fakeDaemon(plan, ran),
  );
  for (let i = 0; i < 5; i++) await tick();
  return client;
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/// A small seeded generator, so a failure names the seed that broke it.
function rng(seed: number) {
  let state = seed >>> 0 || 1;
  return () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 0x100000000;
  };
}
const WORDS = ["fix", "the", "flaky", "test", "émoji 🎉", "日本語", "line\nbreak", "  spaced  ", "`code`", "**bold**"];
function randomText(next: () => number): string {
  const count = 1 + Math.floor(next() * 12);
  return Array.from({ length: count }, () => WORDS[Math.floor(next() * WORDS.length)]).join(" ");
}
function randomAttachments(next: () => number, tag: string): ComposerAttachment[] {
  const count = Math.floor(next() * 4);
  return Array.from({ length: count }, (_, index) =>
    next() < 0.5
      ? {
          id: `${tag}-t${index}`,
          kind: "text" as const,
          name: `notes-${index}.txt`,
          mimeType: "text/plain",
          size: 12,
          text: `attached ${tag} ${index}`,
        }
      : {
          id: `${tag}-l${index}`,
          kind: "link" as const,
          name: `src-${index}`,
          mimeType: "inode/directory",
          size: 0,
          path: `/Users/you/src/app/src-${index}`,
        },
  );
}

/// What App.tsx does with a started chat's failed send: a failed row or a prompt acpmux took keeps
/// it in the chat (`keptInChat`); anything else goes back to the composer (`giveBack`).
function keptInChat(error: unknown): boolean {
  const fields = (error ?? {}) as { failedRow?: unknown; taken?: unknown };
  return fields.failedRow !== undefined || fields.taken === true;
}

// A dropped connection schedules the pane's reconnect on `window`, so the send tests run in a page.
describe("sends", () => {
  const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  const pageScope = globalThis as Record<string, unknown>;
  const hadPage = "window" in pageScope;
  const savedPage = pageScope.window;
  beforeAll(() => {
    pageScope.window = dom.window;
  });
  afterAll(async () => {
    await teardownDom([["window", hadPage, savedPage]], { window: dom.window, scope: pageScope });
  });

  test("a failed send keeps its words and attachments in exactly one place, under load", async () => {
    const ROUNDS = 400;
    const next = rng(0x5eed);
    const ran: string[] = [];
    const plan: Outcome[] = [];
    let client = await connect(plan, ran);
    const opened = [client];
    try {
      for (let round = 0; round < ROUNDS; round += 1) {
        const text = randomText(next);
        const attachments = randomAttachments(next, `r${round}`);
        const outcome: Outcome = next() < 0.2 ? "ok" : FAILURES[Math.floor(next() * FAILURES.length)];
        // Half the sends hold the prompt until acpmux takes it (a new chat's composer, the Quick
        // Composer); the rest let go at once, as a started chat's composer does.
        const holds = next() < 0.5;
        plan.push(outcome);
        // The started chat's composer empties on Send; the pane puts the prompt back on a refusal.
        const composer: { text: string; attachments: ComposerAttachment[] } = {
          text: "",
          attachments: [],
        };
        const promptId = `p-${round}`;
        const error = await client
          .send(text, attachments, promptId, holds ? () => undefined : undefined)
          .then(() => undefined)
          .catch((caught: unknown) => caught ?? new Error("rejected"));
        const where = `round ${round} (${outcome}, ${holds ? "held" : "let go"})`;
        if (outcome === "ok") {
          expect(error, where).toBeUndefined();
          expect(
            ran.filter((id) => id === promptId),
            where,
          ).toEqual([promptId]);
          continue;
        }
        expect(error, where).toBeDefined();
        expect(ran.includes(promptId), where).toBe(false);
        const failedRow = (error as { failedRow?: string }).failedRow;
        if (keptInChat(error)) {
          expect(failedRow, `${where}: kept in the chat, so a failed row holds it`).toBeDefined();
          // The row holds the prompt as typed, for Retry and Edit.
          const [copy] = client.failedPromptCopies([failedRow!]);
          expect({ text: copy?.input, attachments: copy?.attachments }, where).toEqual({ text, attachments });
        } else {
          composer.text = text;
          composer.attachments = attachments;
          // One copy: the composer has it, so the chat draws no failed row with a Retry beside it.
          expect(client.failedPromptCopies([`local-${promptId}`]), where).toEqual([]);
        }
        expect(composer.text === text || failedRow !== undefined, where).toBe(true);
        // A held prompt never leaves its composer, so it never becomes a row too.
        if (holds) expect(failedRow, where).toBeUndefined();
        // A dropped connection is gone; the pane connects again.
        if (outcome === "drop" || client.isClosed) {
          client.close();
          client = await connect(plan, ran);
          opened.push(client);
        }
      }
    } finally {
      for (const each of opened) each.close();
    }
  });

  test("Retry and Edit on a failed row: one submit is run once, under its first prompt id", async () => {
    const next = rng(0xc0ffee);
    const ran: string[] = [];
    const plan: Outcome[] = [];
    const client = await connect(plan, ran);
    try {
      for (let round = 0; round < 200; round += 1) {
        const text = randomText(next);
        const attachments = randomAttachments(next, `retry${round}`);
        const promptId = `retry-${round}`;
        // The first try fails with a reply (so a row keeps it); a few Retries fail again.
        const failures = 1 + Math.floor(next() * 3);
        for (let i = 0; i < failures; i += 1) plan.push(next() < 0.5 ? "rpc" : "gone");
        const error = await client.send(text, attachments, promptId).catch((caught: unknown) => caught);
        let rowId = (error as { failedRow?: string }).failedRow;
        expect(rowId, `round ${round}`).toBeDefined();
        if (next() < 0.25) {
          // Edit takes it back to the composer as typed; the row goes, so nothing can Retry it too.
          expect(client.takeFailedPrompt(rowId!)).toEqual({
            input: text,
            attachments,
          });
          expect(client.failedPromptCopies([rowId!])).toEqual([]);
          plan.length = 0;
          continue;
        }
        for (let attempt = 1; attempt < failures; attempt += 1) {
          const again = await client.retryPrompt(rowId!).catch((caught: unknown) => caught);
          rowId = (again as { failedRow?: string }).failedRow;
          expect(rowId, `round ${round} retry ${attempt}`).toBeDefined();
          const [copy] = client.failedPromptCopies([rowId!]);
          expect({ text: copy?.input, attachments: copy?.attachments }).toEqual({ text, attachments });
        }
        // The Retry that goes runs the prompt once, under the id the first try went with.
        await client.retryPrompt(rowId!);
        expect(
          ran.filter((id) => id === promptId),
          `round ${round}`,
        ).toEqual([promptId]);
        // Its row is spent: a second Retry (a double click, a replay after reload) sends nothing.
        expect(await client.retryPrompt(rowId!)).toBeUndefined();
        expect(ran.filter((id) => id === promptId)).toHaveLength(1);
      }
      expect(new Set(ran).size).toBe(ran.length);
    } finally {
      client.close();
    }
  });
});

// Drafts: the pane writes a chat's draft to acpmux (`chat.writeDraft`) and to the page's remount
// cache. While acpmux cannot take it, the newest text per chat waits and lands once acpmux answers.
describe("drafts", () => {
  const scope = globalThis as Record<string, unknown>;
  const hadWindow = "window" in scope;
  const savedWindow = scope.window;
  let storage = new Map<string, string>();
  const hadStorage = "localStorage" in scope;
  const savedStorage = scope.localStorage;

  beforeEach(async () => {
    storage = new Map();
    scope.localStorage = {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => void storage.set(key, value),
      removeItem: (key: string) => void storage.delete(key),
    };
    scope.window = {
      cmuxAcpmuxActions: { "chat.writeDraft": async () => undefined },
    };
    await settlePendingDraftWrites();
  });
  afterEach(async () => {
    scope.window = {
      cmuxAcpmuxActions: { "chat.writeDraft": async () => undefined },
    };
    await settlePendingDraftWrites();
    await teardownDom(
      [
        ["window", hadWindow, savedWindow],
        ["localStorage", hadStorage, savedStorage],
      ],
      { scope },
    );
  });

  test("drafts typed while acpmux refuses every write are kept per chat and land newest once it answers", async () => {
    const next = rng(0xd4af7);
    const held = new Map<string, string>();
    let up = false;
    scope.window = {
      cmuxAcpmuxActions: {
        "chat.writeDraft": async (params: Record<string, unknown>) => {
          if (!up)
            throw Object.assign(new Error("not connected"), {
              code: "native.not_connected",
            });
          held.set(String(params.sessionId), String(params.text));
        },
      },
    };
    const chats = Array.from({ length: 12 }, (_, index) => `draft-chat-${index}`);
    const typed = new Map<string, string>();
    for (let key = 0; key < 3000; key += 1) {
      const chat = chats[Math.floor(next() * chats.length)]!;
      // A keystroke, a paste, or the person clearing the prompt (the Send's clear included).
      const text = next() < 0.05 ? "" : `${typed.get(chat) ?? ""}${randomText(next).slice(0, 3)}`;
      typed.set(chat, text);
      noteDraftEdited(chat);
      writePersistedDraft(chat, text);
      if (key % 97 === 0) await tick();
    }
    await settlePendingDraftWrites();
    // Nothing landed, and nothing was dropped: each chat still owns its newest text.
    expect(held.size).toBe(0);
    for (const chat of chats) {
      expect(draftHistory(chat).pendingWrite).toBe(true);
      expect(readPersistedDraft(chat)).toBe(typed.get(chat)?.trim() ? typed.get(chat) : undefined);
    }
    // A reload while acpmux is away reads its old draft: what the page holds wins, never the old one.
    for (const chat of chats) {
      const current = typed.get(chat) ?? "";
      const shown = hydratedDraft({
        current,
        restored: "an older draft",
        ...draftHistory(chat),
        // The page read this chat's draft in an earlier mount.
        read: true,
      });
      expect(shown.text).toBe(current);
    }
    up = true;
    await settlePendingDraftWrites();
    for (let round = 0; round < 20 && chats.some((chat) => draftHistory(chat).pendingWrite); round += 1) await tick();
    for (const chat of chats) {
      expect(held.get(chat)).toBe(typed.get(chat) ?? "");
      expect(draftHistory(chat).pendingWrite).toBe(false);
    }
  });

  test("two panes on one chat and a chat switch never put an older draft over a newer one", async () => {
    const held = new Map<string, string>();
    scope.window = {
      cmuxAcpmuxActions: {
        "chat.writeDraft": async (params: Record<string, unknown>) =>
          void held.set(String(params.sessionId), String(params.text)),
      },
    };
    const next = rng(0xbeef);
    for (let round = 0; round < 300; round += 1) {
      const chat = `pane-chat-${round}`;
      // Pane A typed and acpmux holds it.
      const first = randomText(next);
      noteDraftEdited(chat);
      writePersistedDraft(chat, first);
      await settlePendingDraftWrites();
      markDraftRead(chat);
      // Pane B, on the same chat, typed more; pane A reads it (a switch back, a reload): B's wins.
      const newer = `${first} ${randomText(next)}`;
      held.set(chat, newer);
      const shown = hydratedDraft({
        current: first,
        restored: newer,
        ...draftHistory(chat),
      });
      expect(draftHistory(chat).read).toBe(true);
      expect(shown.text).toBe(newer);
      expect(shown.write).toBe(false);
      // A New session is another chat: this chat's draft is untouched by it.
      expect(readPersistedDraft(`${chat}-new`)).toBeUndefined();
      expect(held.get(chat)).toBe(newer);
    }
  });
});

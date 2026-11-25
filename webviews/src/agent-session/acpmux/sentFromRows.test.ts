import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "./model";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, { window: dom.window, document: dom.window.document });
});
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

type Feed = {
  emit: (target: string, step: unknown, at?: number) => void;
  touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
  record: (target: string, step: unknown, at?: number) => void;
};

const settle = async (check: () => boolean) => {
  // timeout: test-only bound; a row that never shows fails the test instead of hanging it.
  const deadline = performance.now() + 2_000;
  while (!check()) {
    if (performance.now() > deadline) throw new Error("timed out waiting for the sent-from row");
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  }
};

async function connect(records: unknown[]) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  forgetTail(mockHost.sessionId!);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const feed = socket as unknown as Feed;
  const target = mockHost.sessionId!;
  for (const step of records) feed.record(target, step);
  let shown: AcpmuxSnapshot | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      shown = snapshot;
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await settle(() => shown?.summary?.sessionId === target);
  return { client, feed, target, snapshot: () => shown, close: () => client.close?.() };
}

const claim = (promptId: string) => ({
  mux: "sender_claim",
  msg: {
    promptId,
    claimed: { harness: "claude-code", entrypoint: "claude-desktop", sessionId: "cc-1", selfReported: true },
    checked: { harness: "claude-code", app: "Claude.app", peerPid: 50 },
  },
});
const prompt = (promptId: string) => ({ mux: "user_message", msg: { promptId, text: "from the desktop" } });
const row = (shown: AcpmuxSnapshot | undefined, promptId: string) =>
  shown?.rows.find((r) => r.kind === "user" && r.promptId === promptId);

test("a replayed sender_claim draws on the row of the prompt it names, and on no other", async () => {
  const io = await connect([claim("p-desktop"), prompt("p-desktop"), prompt("p-own")]);
  try {
    await settle(() => row(io.snapshot(), "p-own") !== undefined);
    expect(row(io.snapshot(), "p-desktop")?.sentFrom).toMatchObject({
      label: "Claude desktop",
      sessionId: "cc-1",
      confirmed: true,
    });
    expect(row(io.snapshot(), "p-own")?.sentFrom).toBeUndefined();
  } finally {
    io.close();
  }
});

test("a live sender_claim draws on the prompt that follows it", async () => {
  const io = await connect([]);
  try {
    io.feed.emit(io.target, claim("p-live"));
    io.feed.emit(io.target, prompt("p-live"));
    await settle(() => row(io.snapshot(), "p-live") !== undefined);
    expect(row(io.snapshot(), "p-live")?.sentFrom?.label).toBe("Claude desktop");
  } finally {
    io.close();
  }
});

test("a send its harness shell named (fromAgent) draws its sender_claim on the incoming message", async () => {
  const named = {
    mux: "user_message",
    // As acpmux records it (prompt_provenance.rs `named_sender`).
    msg: {
      promptId: "p-named",
      text: "from the desktop",
      fromAgent: "Claude Code desktop on mac · cc-1",
      _meta: {
        provenance: {
          kind: "agent_message",
          from: "fromAgent",
          fromName: "Claude Code desktop on mac · cc-1",
          to: "x",
        },
      },
    },
  };
  const io = await connect([claim("p-named"), named]);
  try {
    await settle(() => row(io.snapshot(), "p-named") !== undefined);
    const shown = row(io.snapshot(), "p-named");
    expect(shown?.incoming?.kind).toBe("message");
    expect(shown?.sentFrom).toMatchObject({ label: "Claude desktop", confirmed: true });
  } finally {
    io.close();
  }
});

test("a sender_claim that comes after its prompt's row still draws on it", async () => {
  const io = await connect([prompt("p-late"), claim("p-late")]);
  try {
    await settle(() => row(io.snapshot(), "p-late")?.sentFrom !== undefined);
    expect(row(io.snapshot(), "p-late")?.sentFrom?.label).toBe("Claude desktop");
  } finally {
    io.close();
  }
});

test("a live sender_claim after its prompt's row draws on it", async () => {
  const io = await connect([]);
  try {
    io.feed.emit(io.target, prompt("p-after"));
    await settle(() => row(io.snapshot(), "p-after") !== undefined);
    io.feed.emit(io.target, claim("p-after"));
    await settle(() => row(io.snapshot(), "p-after")?.sentFrom !== undefined);
    expect(row(io.snapshot(), "p-after")?.sentFrom?.label).toBe("Claude desktop");
  } finally {
    io.close();
  }
});

// The default route of another agent's send (agentInbox): an inbox notice names it by its prompt id
// (acpmux hub/inbox.rs `render`), and its thread line carries the claim of that id.
const inboxNoticeOf = (promptId: string) => ({
  mux: "user_message",
  msg: {
    promptId: `notice-${promptId}`,
    text: "You have 1 new message.",
    _meta: {
      provenance: {
        kind: "inbox_notice",
        noticeId: `notice-${promptId}`,
        threads: [
          {
            threadId: "from:Claude Code desktop on mac · cc-1",
            label: "",
            new: 1,
            from: ["Claude Code desktop on mac · cc-1"],
            promptIds: [promptId],
            preview: "from the desktop",
            messages: [{ promptId, from: "Claude Code desktop on mac · cc-1", text: "from the desktop" }],
          },
        ],
      },
    },
  },
});
const noticeThread = (shown: AcpmuxSnapshot | undefined, promptId: string) => {
  const notice = shown?.rows.find((r) => r.kind === "user" && r.incoming?.kind === "inbox");
  return notice?.incoming?.kind === "inbox"
    ? notice.incoming.notice.threads.find((t) => t.promptIds.includes(promptId))
    : undefined;
};

test("an inbox notice's thread carries the sender_claim of each message it names", async () => {
  const io = await connect([claim("p-inbox"), inboxNoticeOf("p-inbox")]);
  try {
    await settle(() => noticeThread(io.snapshot(), "p-inbox") !== undefined);
    expect(noticeThread(io.snapshot(), "p-inbox")?.sentFrom?.["p-inbox"]).toMatchObject({
      label: "Claude desktop",
      confirmed: true,
    });
  } finally {
    io.close();
  }
});

test("a sender_claim after its inbox notice still reaches the notice's thread", async () => {
  const io = await connect([inboxNoticeOf("p-inbox-late")]);
  try {
    await settle(() => noticeThread(io.snapshot(), "p-inbox-late") !== undefined);
    io.feed.emit(io.target, claim("p-inbox-late"));
    await settle(() => noticeThread(io.snapshot(), "p-inbox-late")?.sentFrom !== undefined);
    expect(noticeThread(io.snapshot(), "p-inbox-late")?.sentFrom?.["p-inbox-late"]?.label).toBe("Claude desktop");
  } finally {
    io.close();
  }
});

test("a sender_claim after a harness-named message's row still draws on it", async () => {
  const named = {
    mux: "user_message",
    msg: {
      promptId: "p-named-late",
      text: "from the desktop",
      fromAgent: "Claude Code desktop on mac · cc-1",
      _meta: {
        provenance: {
          kind: "agent_message",
          from: "fromAgent",
          fromName: "Claude Code desktop on mac · cc-1",
          to: "x",
        },
      },
    },
  };
  const io = await connect([named]);
  try {
    await settle(() => row(io.snapshot(), "p-named-late") !== undefined);
    io.feed.emit(io.target, claim("p-named-late"));
    await settle(() => row(io.snapshot(), "p-named-late")?.sentFrom !== undefined);
    expect(row(io.snapshot(), "p-named-late")?.sentFrom?.label).toBe("Claude desktop");
  } finally {
    io.close();
  }
});

test("a sender_claim on an older page draws on its prompt's row already held from a newer one", async () => {
  // The attach holds the newest 2000 records (mock.ts `page`), so the claim lands on the page
  // loaded next while its prompt's row is already drawn.
  const filler = Array.from({ length: 2100 }, (_, i) => prompt(`p-filler-${i}`));
  const io = await connect([claim("p-held"), ...filler, prompt("p-held")]);
  try {
    await settle(() => row(io.snapshot(), "p-held") !== undefined);
    expect(row(io.snapshot(), "p-held")?.sentFrom).toBeUndefined();
    for (let pages = 0; io.snapshot()?.canLoadOlder && pages < 10; pages += 1) await io.client.loadOlder();
    expect(io.snapshot()?.canLoadOlder).toBe(false);
    expect(row(io.snapshot(), "p-held")?.sentFrom?.label).toBe("Claude desktop");
  } finally {
    io.close();
  }
});

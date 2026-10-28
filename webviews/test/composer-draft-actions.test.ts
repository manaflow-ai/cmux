import { expect, test } from "bun:test";
import { draftTextActions } from "../src/agent-session/acpmux/draftTextActions";

const sessionId = "session";
for (const draft of ["newer edit from another host", "", null]) {
  test("daemon reply wins over a stale native mirror: " + JSON.stringify(draft), async () => {
    const reply = { sessionId, draft };
    const nativeCalls: unknown[][] = [];
    const actions = draftTextActions(
      { readDraft: async () => reply, writeDraft: async () => undefined },
      async (method, params) => {
        nativeCalls.push([method, params]);
        return "stale native draft";
      },
    );
    expect(await actions["chat.readDraft"]({ sessionId })).toEqual(reply);
    expect(nativeCalls).toEqual([["chat.draftText.set", { sessionId, text: draft ?? "" }]]);
  });
}

for (const reply of [undefined, {}, { sessionId }, { sessionId, draft: 12 }]) {
  test("missing daemon draft falls back to native: " + JSON.stringify(reply), async () => {
    const actions = draftTextActions(
      { readDraft: async () => reply, writeDraft: async () => undefined },
      async () => "recovered native draft",
    );
    expect(await actions["chat.readDraft"]({ sessionId })).toBe("recovered native draft");
  });
}

test("unavailable daemon preserves an intentional native clear", async () => {
  const actions = draftTextActions(
    {
      readDraft: async () => {
        throw new Error("offline");
      },
      writeDraft: async () => undefined,
    },
    async () => "",
  );
  expect(await actions["chat.readDraft"]({ sessionId })).toBe("");
});

test("writes mirror the same session and text before daemon persistence", async () => {
  const calls: unknown[] = [];
  const actions = draftTextActions(
    {
      readDraft: async () => undefined,
      writeDraft: async (...args) => {
        calls.push(args);
      },
    },
    async (method, params) => {
      calls.push([method, params]);
    },
  );
  await actions["chat.writeDraft"]({ sessionId, text: "" });
  expect(calls).toEqual([
    ["chat.draftText.set", { sessionId, text: "" }],
    [sessionId, ""],
  ]);
});

test("an authoritative daemon clear updates the mirror for a later fallback", async () => {
  let available = true;
  let mirror = "stale native draft";
  const actions = draftTextActions(
    {
      readDraft: async () => (available ? { sessionId, draft: null } : undefined),
      writeDraft: async () => undefined,
    },
    async (method, params) => {
      if (method === "chat.draftText.set") mirror = String(params.text);
      return method === "chat.draftText.get" ? mirror : undefined;
    },
  );
  expect(await actions["chat.readDraft"]({ sessionId })).toEqual({ sessionId, draft: null });
  available = false;
  expect(await actions["chat.readDraft"]({ sessionId })).toBe("");
});

test("a newer local write wins over an older read and its mirror sync", async () => {
  let release!: () => void;
  const reading = new Promise<void>((resolve) => {
    release = resolve;
  });
  let mirror = "old";
  let daemon = "daemon old";
  const actions = draftTextActions(
    {
      readDraft: async () => {
        await reading;
        return { sessionId, draft: daemon };
      },
      writeDraft: async (_id, text) => {
        daemon = text;
      },
    },
    async (method, params) => {
      if (method === "chat.draftText.set") mirror = String(params.text);
      return method === "chat.draftText.get" ? mirror : undefined;
    },
  );
  const oldRead = actions["chat.readDraft"]({ sessionId });
  const write = actions["chat.writeDraft"]({ sessionId, text: "new local" });
  release();
  expect(await oldRead).toBe("new local");
  await write;
  expect(await actions["chat.readDraft"]({ sessionId })).toEqual({ sessionId, draft: "new local" });
});

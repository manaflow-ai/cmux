import { expect, test } from "bun:test";
import { draftTextActions } from "../src/agent-session/acpmux/draftTextActions";

const sessionId = "session";
for (const draft of ["newer edit from another host", "", null]) {
  test("daemon reply wins over a stale native mirror: " + JSON.stringify(draft), async () => {
    const reply = { sessionId, draft };
    let nativeReads = 0;
    const actions = draftTextActions({ readDraft: async () => reply, writeDraft: async () => undefined }, async () => {
      nativeReads++;
      return "stale native draft";
    });
    expect(await actions["chat.readDraft"]({ sessionId })).toEqual(reply);
    expect(nativeReads).toBe(0);
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

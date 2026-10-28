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

test("a refused mirror clear stays authoritative across an unavailable daemon read", async () => {
  let available = true;
  let mirror = "stale native draft";
  let release!: () => void;
  let started!: () => void;
  const refusal = new Promise<void>((resolve) => {
    release = resolve;
  });
  const entered = new Promise<void>((resolve) => {
    started = resolve;
  });
  const actions = draftTextActions(
    {
      readDraft: async () => (available ? { sessionId, draft: null } : undefined),
      writeDraft: async () => undefined,
    },
    async (method, params) => {
      if (method === "chat.draftText.set" && params.text === "") {
        started();
        await refusal;
        throw new Error("native mirror refused");
      }
      return method === "chat.draftText.get" ? mirror : undefined;
    },
  );
  const first = actions["chat.readDraft"]({ sessionId });
  await started;
  available = false;
  const second = actions["chat.readDraft"]({ sessionId });
  release();
  expect(await first).toEqual({ sessionId, draft: null });
  expect(await second).toBe("");
  mirror = "stale after clear";
  const newer = actions["chat.writeDraft"]({ sessionId, text: "newer local" });
  expect(await newer).toBeUndefined();
  expect(await actions["chat.readDraft"]({ sessionId })).toEqual({ sessionId, draft: "newer local" });
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

for (const duringMirrorSync of [false, true]) {
  test(`a newer local write wins during ${duringMirrorSync ? "mirror sync" : "daemon read"}`, async () => {
    let release!: () => void, reached!: () => void;
    const reading = new Promise<void>((resolve) => {
      release = resolve;
    });
    const started = new Promise<void>((resolve) => {
      reached = resolve;
    });
    const block = async () => {
      reached();
      await reading;
    };
    let mirror = "old",
      daemon = "daemon old";
    const actions = draftTextActions(
      {
        readDraft: async () => {
          if (!duringMirrorSync) await block();
          return { sessionId, draft: daemon };
        },
        writeDraft: async (_id, text) => {
          daemon = text;
        },
      },
      async (method, params) => {
        if (method === "chat.draftText.set") {
          if (duringMirrorSync && params.text === "daemon old") await block();
          mirror = String(params.text);
        }
        return method === "chat.draftText.get" ? mirror : undefined;
      },
    );
    const oldRead = actions["chat.readDraft"]({ sessionId });
    await started;
    const write = actions["chat.writeDraft"]({ sessionId, text: "new local" });
    release();
    expect(await oldRead).toBe("new local");
    await write;
    expect(mirror).toBe("new local");
    expect(await actions["chat.readDraft"]({ sessionId })).toEqual({ sessionId, draft: "new local" });
  });
}

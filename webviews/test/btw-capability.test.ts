import { expect, test } from "bun:test";
import { askBtwQuestion, BTW_INLINE, supportsBtwInline } from "../src/agent-session/acpmux/btwCapability";

test("inline btw capability gates the new reply shape", () => {
  expect(BTW_INLINE).toBe("btw-inline-v1");
  expect(supportsBtwInline(new Set([BTW_INLINE]))).toBe(true);
  expect(supportsBtwInline(new Set(["acpmux-v1"]))).toBe(false);
  expect(supportsBtwInline(undefined)).toBe(false);
});

function fixture(capabilities?: ReadonlySet<string>) {
  const opened: string[] = [];
  const legacy: string[][] = [];
  const inline: string[][] = [];
  let reply!: (sessionId: string) => void;
  const client = {
    capabilities,
    selectedSession: "main",
    selectionToken: 1,
    btw(question: string, sessionId: string) {
      legacy.push([question, sessionId]);
      return new Promise<string>((resolve) => {
        reply = resolve;
      });
    },
  };
  const actions = {
    async inline(question: string, sessionId: string) {
      inline.push([question, sessionId]);
      return "answer";
    },
    async openSide(sessionId: string) {
      opened.push(sessionId);
    },
    openedMessage: () => "opened",
    staleMessage: () => "stale",
  };
  return { client, actions, opened, legacy, inline, reply: (id: string) => reply(id) };
}

test("the composer routes an advertised inline question without creating a legacy side", async () => {
  const f = fixture(new Set([BTW_INLINE]));
  expect(await askBtwQuestion(f.client, "why?", "main", f.actions)).toBe("answer");
  expect(f.inline).toEqual([["why?", "main"]]);
  expect(f.legacy).toEqual([]);
  expect(f.opened).toEqual([]);
});

for (const code of ["native.invalid_request", "unsupported"]) {
  test(`an older app host falls back on ${code}`, async () => {
    const f = fixture(new Set([BTW_INLINE]));
    f.actions.inline = async () => {
      throw Object.assign(new Error(code), { code });
    };
    const answer = askBtwQuestion(f.client, "why?", "main", f.actions);
    await Promise.resolve();
    f.reply("side");
    expect(await answer).toBe("opened");
    expect(f.legacy).toEqual([["why?", "main"]]);
    expect(f.opened).toEqual(["side"]);
  });
}

test("a stale selection does not start a legacy side after an old host rejects inline", async () => {
  const f = fixture(new Set([BTW_INLINE]));
  let reject!: (error: unknown) => void;
  f.actions.inline = () =>
    new Promise<string>((_resolve, fail) => {
      reject = fail;
    });
  const answer = askBtwQuestion(f.client, "why?", "main", f.actions);
  f.client.selectionToken += 2;
  reject({ code: "native.invalid_request" });
  await expect(answer).rejects.toThrow("stale");
  expect(f.legacy).toEqual([]);
  expect(f.opened).toEqual([]);
});

test("an inline refusal or uncertain answer never starts duplicate legacy work", async () => {
  for (const code of ["gesture_required", "folder_untrusted", "native.timed_out", "native.failed"]) {
    const f = fixture(new Set([BTW_INLINE]));
    const error = Object.assign(new Error(code), { code });
    f.actions.inline = async () => {
      throw error;
    };
    await expect(askBtwQuestion(f.client, "why?", "main", f.actions)).rejects.toBe(error);
    expect(f.legacy).toEqual([]);
    expect(f.opened).toEqual([]);
  }
});

test("a daemon without the id gets a legacy question and its side session opens", async () => {
  const f = fixture();
  const answer = askBtwQuestion(f.client, "why?", "main", f.actions);
  f.reply("side");
  expect(await answer).toBe("opened");
  expect(f.legacy).toEqual([["why?", "main"]]);
  expect(f.inline).toEqual([]);
  expect(f.opened).toEqual(["side"]);
});

test("switching away during the legacy request prevents a late side pane, even after switching back", async () => {
  const f = fixture();
  const answer = askBtwQuestion(f.client, "why?", "main", f.actions);
  f.client.selectionToken += 2;
  f.reply("side");
  await expect(answer).rejects.toThrow("stale");
  expect(f.opened).toEqual([]);
});

test("a stale composer starts neither inline nor legacy work", async () => {
  const f = fixture(new Set([BTW_INLINE]));
  f.client.selectedSession = "other";
  await expect(askBtwQuestion(f.client, "why?", "main", f.actions)).rejects.toThrow("stale");
  expect(f.inline).toEqual([]);
  expect(f.legacy).toEqual([]);
});

for (const reason of ["trust.pending", "trust.untrusted"] as const) {
  test(`${reason} reaches the folder trust route without spending a second gesture`, async () => {
    const f = fixture(new Set([BTW_INLINE]));
    const refusals: unknown[] = [];
    const error = Object.assign(new Error("Trust this folder first"), {
      code: reason,
      details: { reason, cwd: "/untrusted" },
    });
    const client = {
      ...f.client,
      routeTrustRefusal(refusal: unknown, again?: () => void) {
        refusals.push(refusal);
        expect(again).toBeUndefined();
        return true;
      },
    };
    f.actions.inline = async () => {
      throw error;
    };
    await expect(askBtwQuestion(client, "why?", "main", f.actions)).rejects.toBe(error);
    expect(refusals).toEqual([{ reason, cwd: "/untrusted" }]);
    expect(f.legacy).toEqual([]);
  });
}

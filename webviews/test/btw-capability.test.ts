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

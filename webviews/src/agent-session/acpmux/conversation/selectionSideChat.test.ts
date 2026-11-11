// l10n-allow-file: test fixtures.
// #40948: the selection bar's Ask in side chat (selectionSideChat.ts). The right-click menu's Open
// in Side Chat shows only on a row of a finished turn the chat can fork from, so it was missing on
// a working chat's selection, on an older turn of a chat that forks only at its end, and on a
// selection in a turn still running. The bar's forks the chat itself, on every selection, and says
// why where no side chat can open.
import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "../model";
import { translate } from "../i18n";
import { CmuxCommandRefused } from "../cmuxCommands";
import { messageMenuTarget } from "./messageMenu";
import { askSelectionInSideChat } from "./selectionSideChat";

const rows = [
  { id: "user-1", kind: "user", seq: 1, text: "Why does it retry?" },
  { id: "assistant-2", kind: "assistant", seq: 2, text: "Retry only on 429 and 503." },
  { id: "summary-3", kind: "turnSummary", seq: 3 },
  { id: "user-4", kind: "user", seq: 4, text: "And on 500?" },
  { id: "assistant-5", kind: "assistant", seq: 5, text: "No, a 500 is final." },
  { id: "summary-6", kind: "turnSummary", seq: 6 },
] as unknown as AcpmuxSnapshot["rows"];

const chat = (over: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot =>
  ({
    sessionId: "s-1",
    canFork: true,
    isWorking: false,
    connection: "connected",
    rows,
    sessions: [],
    commands: [],
    summary: { family: "gemini" },
    ...over,
  }) as unknown as AcpmuxSnapshot;

function host(result: Promise<unknown> = Promise.resolve()) {
  const sides: Record<string, unknown>[] = [];
  const notices: string[] = [];
  return {
    sides,
    notices,
    host: {
      side: (params: Record<string, unknown>) => {
        sides.push(params);
        return result;
      },
      notice: (text: string) => notices.push(text),
      t: translate,
    },
  };
}

const flush = () => new Promise((done) => setTimeout(done, 0));

test("the right-click menu offers Open in Side Chat only on some rows (the cause of #40948)", () => {
  // An older turn of a chat that forks only at its end, and any row of a working chat: no side chat row.
  expect(messageMenuTarget(chat(), "assistant-2", true)?.sideChat).toBeUndefined();
  expect(messageMenuTarget(chat({ isWorking: true }), "assistant-5", true)?.sideChat).toBeUndefined();
  // The latest finished turn of an idle chat: it shows.
  expect(messageMenuTarget(chat(), "assistant-5", true)?.sideChat).toBe(true);
});

test("Ask in side chat on an older turn forks the chat and asks the quote in a split on the right", () => {
  const { sides, notices, host: h } = host();
  expect(askSelectionInSideChat("only on 429", chat(), "local", h)).toBe(true);
  expect(sides).toEqual([{ throughSeq: 6, splitRight: true, prompt: "> only on 429\n\nExplain this." }]);
  expect(notices).toEqual([]);
});

test("Ask in side chat in a working chat forks it as it is now", () => {
  const { sides, host: h } = host();
  expect(askSelectionInSideChat("a 500 is final", chat({ isWorking: true }), "local", h)).toBe(true);
  expect(sides).toEqual([{ live: true, splitRight: true, prompt: "> a 500 is final\n\nExplain this." }]);
});

test("where no side chat can open, it says why instead of doing nothing", () => {
  const quick = host();
  expect(askSelectionInSideChat("x", chat(), undefined, quick.host)).toBe(false);
  expect(quick.notices).toEqual([translate("message.selectionSideUnavailable")]);
  const empty = host();
  expect(askSelectionInSideChat("x", chat({ rows: [] }), "local", empty.host)).toBe(false);
  expect(empty.notices).toEqual([translate("notice.forkNothingYet")]);
  const offline = host();
  expect(askSelectionInSideChat("x", chat({ connection: "disconnected" }), "local", offline.host)).toBe(false);
  expect(offline.notices).toEqual([translate("composer.cmuxForkBusy")]);
  expect([quick, empty, offline].flatMap((one) => one.sides)).toEqual([]);
});

test("a side chat that fails to open says so", async () => {
  const failed = host(Promise.reject(new Error("fork refused")));
  askSelectionInSideChat("x", chat(), "local", failed.host);
  await flush();
  expect(failed.notices).toEqual([translate("notice.forkFailedReason", { reason: "fork refused" })]);
  const notSent = host(Promise.reject(new CmuxCommandRefused("Prompt not sent")));
  askSelectionInSideChat("x", chat(), "local", notSent.host);
  await flush();
  expect(notSent.notices).toEqual(["Prompt not sent"]);
});

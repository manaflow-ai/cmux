import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { shownChrome } from "./shownChrome";
import { emptySnapshot } from "./snapshotCache";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const modes = {
  availableModes: [{ id: "default" }, { id: "bypassPermissions", name: "Bypass permissions" }],
  currentModeId: "bypassPermissions",
};
function frame(connection: string, summary?: Partial<Summary>, more: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  return {
    ...emptySnapshot(),
    connection,
    sessionId: summary?.sessionId,
    summary: summary as Summary | undefined,
    ...more,
  };
}
const kept = frame("connecting", { sessionId: "chat", harness: "claude", model: "opus", modes, title: "Fix it" });

test("a frame before the attach keeps the mode chip the page already showed", () => {
  const chrome = shownChrome();
  // The open's hold ran out on a slow daemon: the listed row, which names no modes.
  const listed = frame("connected", { sessionId: "chat", harness: "claude", title: "Fix it now" });
  const drawn = chrome.keep(kept, listed);
  expect(drawn.summary?.modes).toBe(modes);
  expect(drawn.summary?.model).toBe("opus");
  // What the newer frame names wins.
  expect(drawn.summary?.title).toBe("Fix it now");
  // The same two summaries draw the same object: the pane compares the summary by identity.
  expect(chrome.keep(kept, { ...listed }).summary).toBe(drawn.summary);
  // A streamed frame with the client's same summary, over the frame drawn, draws the same one too.
  expect(chrome.keep(drawn, { ...listed }).summary).toBe(drawn.summary);
  // The next frame is compared with the one drawn, and still keeps it.
  expect(chrome.keep(drawn, frame("session changed", { sessionId: "chat" })).summary?.modes).toBe(modes);
});

test("a frame that names the chat and no summary keeps the chrome shown", () => {
  const drawn = shownChrome().keep(kept, frame("connected", undefined, { sessionId: "chat" }));
  expect(drawn.summary?.sessionId).toBe("chat");
  expect(drawn.summary?.modes).toBe(modes);
});

test("the attach's frame and every one after it are drawn as given", () => {
  const chrome = shownChrome();
  const attached = frame("attached", { sessionId: "chat", harness: "pi" });
  expect(chrome.keep(kept, attached)).toBe(attached);
  const after = frame("session changed", { sessionId: "chat", harness: "pi" });
  expect(chrome.keep(kept, after)).toBe(after);
  // A new client attaches again: until it has, what shows stays.
  chrome.clientLost();
  expect(chrome.keep(kept, after).summary?.modes).toBe(modes);
});

test("another chat, a failed open and a frame that lacks nothing are drawn as given", () => {
  const chrome = shownChrome();
  const other = frame("connected", { sessionId: "other" });
  expect(chrome.keep(kept, other)).toBe(other);
  const whole = frame("connected", { ...kept.summary! });
  expect(chrome.keep(kept, whole)).toBe(whole);
  const failed = frame("failed", { sessionId: "chat" });
  expect(chrome.keep(kept, failed)).toBe(failed);
  expect(chrome.keep(undefined, other)).toBe(other);
});

test("live state is never kept: a status the page showed is not carried", () => {
  const working = frame("connecting", { sessionId: "chat", modes, status: "working" } as Partial<Summary>);
  const drawn = shownChrome().keep(working, frame("connected", { sessionId: "chat" }));
  expect(drawn.summary?.status).toBeUndefined();
});

test("the model list the page showed stays while the client has none", () => {
  const catalog = [{ id: "opus" }] as unknown as AcpmuxSnapshot["catalog"];
  const drawn = shownChrome().keep({ ...kept, catalog }, frame("connected", { sessionId: "chat" }));
  expect(drawn.catalog).toBe(catalog);
});

test("a read chat whose detail came without its modes keeps the ones it named, on the same harness", () => {
  const chrome = shownChrome();
  // acpmux dropped `modes` from a reply too big to send: the chip stays, on this frame and the next.
  const bare = frame("attached", { sessionId: "chat", harness: "claude", modes: null } as unknown as Partial<Summary>);
  const drawn = chrome.keep(kept, bare);
  expect(drawn.summary?.modes).toBe(modes);
  expect(drawn.summary?.harness).toBe("claude");
  const again = chrome.keep(drawn, { ...bare, isWorking: true });
  expect(again.summary).toBe(drawn.summary);
  // The chat names its modes: those are drawn, and kept from then on.
  const other = { ...modes, currentModeId: "default" };
  const told = frame("session changed", { sessionId: "chat", harness: "claude", modes: other });
  expect(chrome.keep(again, told)).toBe(told);
  expect(chrome.keep(told, { ...bare, connection: "session changed" }).summary?.modes).toBe(other);
});

// l10n-allow-file: test fixture prompts, not shipped UI.
// A send in a Cloud chat whose machine is paused, or whose link went down when the machine paused
// itself, wakes the machine instead of failing (cloudWake.ts): the prompt waits in the pane's hold
// under "Waking the machine…" with no gesture ticket (one would end with the connection the wake
// replaces), goes exactly once when the chat is back, and a failed wake gives it back.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useTrustHeldPrompts } = await import("../src/agent-session/acpmux/trustHeld");
const { cloudSendWakes, cloudTypingWakes } = await import("../src/agent-session/acpmux/cloudWake");
type Held = ReturnType<typeof useTrustHeldPrompts>;
type Entry = Parameters<Parameters<typeof useTrustHeldPrompts>[0]["send"]>[0];

const root = createRoot(dom.window.document.getElementById("root")!);
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
});

const live = { cloud: true, chat: "chat-1", linkUp: true, paused: false, unavailable: false };

test("a send wakes only a Cloud chat whose machine is paused or out of reach", () => {
  expect(cloudSendWakes(live)).toBeUndefined();
  expect(cloudSendWakes({ ...live, linkUp: false })).toBe("chat-1");
  expect(cloudSendWakes({ ...live, paused: true })).toBe("chat-1");
  expect(cloudSendWakes({ ...live, unavailable: true })).toBe("chat-1");
  // Not a Cloud chat, or no chat yet: the send goes as before.
  expect(cloudSendWakes({ ...live, cloud: false, linkUp: false })).toBeUndefined();
  expect(cloudSendWakes({ ...live, chat: undefined, linkUp: false })).toBeUndefined();
});

test("typing wakes a paused Cloud machine once per sleep, before any send", () => {
  const asleep = { ...live, linkUp: false, asleep: true, woke: undefined };
  expect(cloudTypingWakes(asleep)).toBe("chat-1");
  expect(cloudTypingWakes({ ...asleep, unavailable: true, paused: true })).toBe("chat-1");
  // The next keys of the same sleep wake nothing more; another chat's sleep is its own.
  expect(cloudTypingWakes({ ...asleep, woke: "chat-1" })).toBeUndefined();
  expect(cloudTypingWakes({ ...asleep, chat: "chat-2", woke: "chat-1" })).toBe("chat-2");
  // A link that is only connecting (the machine not read as paused) is left alone, and so is a
  // live chat, a chat that is not Cloud, or none.
  expect(cloudTypingWakes({ ...asleep, asleep: false })).toBeUndefined();
  expect(cloudTypingWakes({ ...live, asleep: true, woke: undefined })).toBeUndefined();
  expect(cloudTypingWakes({ ...asleep, cloud: false })).toBeUndefined();
  expect(cloudTypingWakes({ ...asleep, chat: undefined })).toBeUndefined();
});

let shown: Held | undefined;
const sent: Entry[] = [];
const reserved: string[] = [];
const givenBack: string[] = [];
function Probe({ holds }: { holds: boolean }) {
  shown = useTrustHeldPrompts({
    chat: "chat-1",
    cwd: "/Users/you/src/app",
    holds,
    send: async (entry) => {
      sent.push(entry);
      return "chat-1";
    },
    reserve: async (promptId) => {
      reserved.push(promptId);
      return `ticket-${promptId}`;
    },
    putBack: (entries) => givenBack.push(...entries.map((entry) => entry.text)),
    refusedForTrust: () => false,
  });
  return null;
}
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

test("a prompt sent while the machine wakes waits without a ticket and goes once the chat is back", async () => {
  await act(async () => root.render(<Probe holds />));
  await act(async () => shown!.hold("fix the flaky test", [], { chat: "chat-1", cwd: "/Users/you/src/app" }, true));
  expect(shown!.rows.map((row) => [row.prompt, row.held, row.waking])).toEqual([["fix the flaky test", true, true]]);
  expect(shown!.wakingAny()).toBe(true);
  // The wake's attach took the Enter's scope credit; the prompt keeps its grant for when it goes.
  expect(reserved).toEqual([]);
  await settle();
  expect(sent).toEqual([]);

  // The machine is up and the chat listed again: it goes, once.
  await act(async () => root.render(<Probe holds={false} />));
  await settle();
  expect(sent.map((entry) => entry.text)).toEqual(["fix the flaky test"]);
  expect(await sent[0]!.ticket).toBeUndefined();
  await act(async () => root.render(<Probe holds={false} />));
  await settle();
  expect(sent).toHaveLength(1);
  expect(shown!.wakingAny()).toBe(false);
});

test("a wake that fails gives its prompts back, and leaves the folder's own held prompts", async () => {
  sent.length = 0;
  reserved.length = 0;
  await act(async () => root.render(<Probe holds />));
  await act(async () => shown!.hold("held for trust", []));
  await act(async () => shown!.hold("one", [], undefined, true));
  await act(async () => shown!.hold("two", [], undefined, true));
  expect(reserved).toHaveLength(1);
  // A chat shown under its recorded id while it is not listed still lists its waking prompts.
  await act(async () => shown!.hold("unlisted", [], { chat: "chat-missing", cwd: undefined }, true));
  expect(shown!.rowsIn("chat-missing").map((row) => [row.prompt, row.waking])).toEqual([["unlisted", true]]);
  let back: Entry[] = [];
  await act(async () => {
    back = shown!.takeWaking();
  });
  expect(back.map((entry) => entry.text)).toEqual(["one", "two", "unlisted"]);
  expect(shown!.rows.map((row) => row.prompt)).toEqual(["held for trust"]);
  expect(shown!.wakingAny()).toBe(false);
  expect(sent).toEqual([]);
});

// Another agent's message waiting in the queue is no composer-queue row (Leo, 2026-10-25: "I don't
// know why these things are queued up. It's kind of strange."): the transcript draws it at once as
// its received card with "Read after this turn" (conversation/QueuedMessageCard.tsx), its actions in
// the card's ⋯ menu. The queue's rows, its fold and its "N more queued" count are the person's own
// prompts alone (ComposerQueue.tsx).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translatorFor } from "../src/agent-session/acpmux/i18n";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Range: dom.window.Range,
  // useAnchoredCollapse asks the transcript to hold the line with a CustomEvent from this DOM.
  CustomEvent: dom.window.CustomEvent,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const { createRoot } = await import("react-dom/client");
const { ComposerQueue } = await import("../src/agent-session/acpmux/ComposerQueue");
const { QueuedMessageCard } = await import("../src/agent-session/acpmux/conversation/QueuedMessageCard");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { queuedMessageRows } = await import("../src/agent-session/acpmux/conversation/queuedMessages");

const t = translatorFor("en");
const agent = (index: number) => {
  const text = `Lane ${index}: CI is green on #${24000 + index}.`;
  return {
    id: `a${index}`,
    prompt: text,
    message: { name: `lane-${index}`, sessionId: `s-${index}`, text, raw: text },
  };
};
const agents = Array.from({ length: 11 }, (_, index) => agent(index + 1));
const own = (index: number) => ({ id: `p${index}`, prompt: `My prompt ${index}` });

async function show(element: React.ReactElement) {
  if (root) act(() => root!.unmount());
  root = createRoot(host);
  await act(async () => root!.render(element));
}
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

test("eleven agent messages and one prompt: one queue row, no fold, no agent line", async () => {
  await show(
    <ComposerQueue
      queue={[...agents, own(1)] as never}
      t={t}
      onRemove={async () => true}
      onChange={async () => true}
    />,
  );
  const rows = [...host.querySelectorAll<HTMLElement>(".acpmux-queued")];
  expect(rows.map((row) => row.dataset.promptId)).toEqual(["p1"]);
  expect(host.querySelector(".acpmux-queue-fold")).toBeNull();
  expect(host.querySelector(".cv-received")).toBeNull();
  expect(host.querySelector(".acpmux-composer-queue")?.getAttribute("aria-label")).toBe(`${t("composer.queue")} (1)`);
});

test("the fold counts the person's prompts only", async () => {
  // Four prompts among the agents' messages: the fold shows two, and two more queued.
  const queue = [agents[0], own(1), ...agents.slice(1, 6), own(2), own(3), ...agents.slice(6), own(4)];
  await show(<ComposerQueue queue={queue as never} t={t} onRemove={async () => true} onChange={async () => true} />);
  expect([...host.querySelectorAll<HTMLElement>(".acpmux-queued")].map((row) => row.dataset.promptId)).toEqual([
    "p1",
    "p2",
  ]);
  expect(host.querySelector(".acpmux-queue-fold")?.textContent).toBe(t("composer.queueMore", { n: 2 }));
  // Three prompts never fold, however many agents wait.
  await show(
    <ComposerQueue
      queue={[...agents, own(1), own(2), own(3)] as never}
      t={t}
      onRemove={async () => true}
      onChange={async () => true}
    />,
  );
  expect(host.querySelectorAll(".acpmux-queued").length).toBe(3);
  expect(host.querySelector(".acpmux-queue-fold")).toBeNull();
});

test("a paused queue of agent messages alone still offers Resume", async () => {
  const edits: unknown[] = [];
  await show(
    <ComposerQueue
      queue={agents.slice(0, 2) as never}
      paused
      t={t}
      onRemove={async () => true}
      onChange={async (id, edit) => {
        edits.push([id, edit]);
        return true;
      }}
    />,
  );
  expect(host.querySelector(".acpmux-queued")).toBeNull();
  const resume = host.querySelector<HTMLButtonElement>(".acpmux-queue-resume")!;
  await act(async () => resume.click());
  expect(edits).toEqual([["a1", { op: "resume" }]]);
  // And with nothing paused, agent messages alone draw no queue at all.
  await show(<ComposerQueue queue={agents.slice(0, 2) as never} t={t} />);
  expect(host.querySelector(".acpmux-composer-queue")).toBeNull();
});

test("the person's prompt moves past an agent's waiting message in the whole queue", async () => {
  const edits: unknown[] = [];
  await show(
    <ComposerQueue
      queue={[agents[0], own(1), own(2), agents[1]] as never}
      t={t}
      onRemove={async () => true}
      onChange={async (id, edit) => (edits.push([id, edit]), true)}
    />,
  );
  const key = async (id: string, key: string) => {
    const row = host.querySelector<HTMLElement>(`[data-prompt-id="${id}"]`)!;
    row.focus();
    await act(async () =>
      row.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, altKey: true, bubbles: true })),
    );
  };
  // ⌥↑ on the first prompt shown: above the agent's message before it. ⌥↓ on the last: below the one after.
  await key("p1", "ArrowUp");
  await key("p2", "ArrowDown");
  // ⌥↓ between the person's prompts still takes the next one's place.
  await key("p1", "ArrowDown");
  expect(edits).toEqual([
    ["p1", { op: "move", index: 0 }],
    ["p2", { op: "move", index: 3 }],
    ["p1", { op: "move", index: 2 }],
  ]);
});

const items = () =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].map((item) => item.textContent?.trim());
const item = (label: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (each) => each.textContent?.trim() === label,
  )!;

async function card(entry: ReturnType<typeof agent> & { next?: boolean; images?: unknown[] }, calls: string[]) {
  const [row] = queuedMessageRows([entry as never]);
  const actions = {
    steer: async (id: string) => (calls.push(`steer ${id}`), true),
    edit: async (id: string, text: string, images: readonly unknown[]) => (
      calls.push(`edit ${id} ${text} (${images.length} images)`),
      true
    ),
    remove: async (id: string) => (calls.push(`remove ${id}`), true),
    sideChat: async (id: string, text: string) => (calls.push(`side ${id} ${text}`), true),
    // It waits second of three in the whole queue.
    position: () => ({ index: 1, count: 3 }),
    move: async (id: string, index: number) => (calls.push(`move ${id} ${index}`), true),
  };
  await show(
    <TurnActionsContext.Provider value={{ queuedMessages: () => actions }}>
      <QueuedMessageCard row={row!} onOpen={(id) => void calls.push(`open ${id}`)} />
    </TurnActionsContext.Provider>,
  );
}
async function openMenu() {
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="queued-message"]')!.click());
  await settle();
}

test("the received card says when it is read and keeps the queue row's actions in its ⋯ menu", async () => {
  const calls: string[] = [];
  const entry = agent(1);
  await card(entry, calls);
  // The message's own card: the sender's chip, its text, the quiet note; no spinner, no queue row.
  expect(host.querySelector(".cv-received__name")?.textContent).toBe("lane-1");
  expect(host.querySelector(".cv-received__body")?.textContent).toContain("CI is green on #24001");
  expect(host.querySelector(".cv-received__queued")?.textContent).toBe(t("message.readAfterTurn"));
  expect(host.querySelector(".acpmux-queued, .cv-spinner, [data-spinner]")).toBeNull();
  await act(async () => host.querySelector<HTMLButtonElement>("button.cv-received__name")!.click());
  expect(calls).toEqual(["open s-1"]);

  await openMenu();
  expect(items()).toEqual([
    t("composer.queueSteer"),
    t("composer.queueEditMessage"),
    t("composer.queueSideChat"),
    t("composer.queueMoveUp"),
    t("composer.queueMoveDown"),
    t("composer.queueingOff"),
    t("composer.queueDelete"),
  ]);
  await act(async () => item(t("composer.queueSteer")).click());
  await settle();
  expect(calls.at(-1)).toBe("steer a1");
  // Steer goes once: the menu no longer offers it.
  await openMenu();
  expect(items()).not.toContain(t("composer.queueSteer"));
  await act(async () => item(t("composer.queueDelete")).click());
  await settle();
  expect(calls.at(-1)).toBe("remove a1");
  await openMenu();
  await act(async () => item(t("composer.queueEditMessage")).click());
  await settle();
  expect(calls.at(-1)).toBe(`edit a1 ${entry.prompt} (0 images)`);
  await openMenu();
  await act(async () => item(t("composer.queueSideChat")).click());
  await settle();
  expect(calls.at(-1)).toBe(`side a1 ${entry.prompt}`);
  // Move up and Move down place it in the whole queue, as its queue row did.
  await openMenu();
  await act(async () => item(t("composer.queueMoveUp")).click());
  await settle();
  expect(calls.at(-1)).toBe("move a1 0");
  await openMenu();
  await act(async () => item(t("composer.queueMoveDown")).click());
  await settle();
  expect(calls.at(-1)).toBe("move a1 2");
});

test("a message sent now offers no second Steer; one with images keeps them and asks no side chat", async () => {
  await card({ ...agent(2), next: true }, []);
  await openMenu();
  expect(items()).toEqual([
    t("composer.queueEditMessage"),
    t("composer.queueSideChat"),
    t("composer.queueMoveUp"),
    t("composer.queueMoveDown"),
    t("composer.queueingOff"),
    t("composer.queueDelete"),
  ]);
  const calls: string[] = [];
  await card({ ...agent(3), images: [{ id: "img", mimeType: "image/png" }] }, calls);
  await openMenu();
  expect(items()).toEqual([
    t("composer.queueSteer"),
    t("composer.queueEditMessage"),
    t("composer.queueMoveUp"),
    t("composer.queueMoveDown"),
    t("composer.queueingOff"),
    t("composer.queueDelete"),
  ]);
  await act(async () => item(t("composer.queueEditMessage")).click());
  await settle();
  expect(calls.at(-1)).toBe(`edit a3 ${agent(3).prompt} (1 images)`);
});

test("a steer the agent has not read: Read after this step, and Send now in its ⋯ menu, no spinner", async () => {
  const { SteerWaitingActions } = await import("../src/agent-session/acpmux/conversation/QueuedMessageCard");
  const sent: string[] = [];
  await show(<SteerWaitingActions promptId="p-steer" send={(id) => void sent.push(id)} />);
  expect(host.querySelector(".cv-received__queued")?.textContent).toBe(t("message.readAfterStep"));
  expect(host.querySelector(".cv-spinner, [data-spinner]")).toBeNull();
  await openMenu();
  expect(items()).toEqual([t("steer.sendNow")]);
  await act(async () => item(t("steer.sendNow")).click());
  await settle();
  expect(sent).toEqual(["p-steer"]);
});

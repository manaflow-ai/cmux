// l10n-allow-file: test fixture prompts, not shipped UI.
// The X beside a steer the agent has not read yet (conversation/PendingSteer.tsx; Leo, 2026-10-21:
// "THERE'S A CANCEL AND EDIT BY CLICKING THE X BUTTON ON THE SENT MESSAGES TO CLAUDE.. THEY'RE
// STEERS BUT THEY HAVENT BEEN SENT SOMETIMES WITH THE TOOL CALLS AND WHATNOT WAITING"). A click
// asks acpmux to take the steer back (`_acpmux/queue_edit` `withdraw` for its promptId); once it
// did, its text goes back into the composer to edit, and its row goes with acpmux's
// `steer_withdrawn` record. A steer read already has no X, and one the agent read first stays.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { CHAT, connect, fakeDaemon, record } from "./support/agentPairDaemon";

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
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout. A tall viewport mounts every row of these small conversations.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { takeBackSteer } = await import("../src/agent-session/acpmux/conversation/PendingSteer");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const takeBackButtons = () =>
  [...dom.window.document.querySelectorAll("button")].filter(
    (button) => button.getAttribute("aria-label") === translate("composer.queueEditMessage"),
  );
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

async function waitingSteer() {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { promptId: "p-turn", text: "Add retries" }],
      ["mux", "user_message", { promptId: "p-steer", text: "Also keep the old flag working", steer: true }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  const restored: string[] = [];
  const actions = {
    unsteer: (row: Parameters<typeof takeBackSteer>[0]) =>
      takeBackSteer(row, {
        withdraw: (promptId) => client.editQueued(promptId, { op: "withdraw" }).then((reply) => reply?.ok === true),
        attachments: (rowId) => client.promptAttachments(rowId),
        restore: (text) => restored.push(text),
      }),
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = () =>
    act(async () =>
      root.render(
        <TurnActionsContext.Provider value={actions}>
          <VirtualTranscript rows={rows()} onToggleActivity={() => {}} expanded={new Set()} />
        </TurnActionsContext.Provider>,
      ),
    );
  return { daemon, rows, restored, root, render };
}

test("the X on a waiting steer takes it back into the composer, and its row goes", async () => {
  const { daemon, rows, restored, root, render } = await waitingSteer();
  try {
    await render();
    const [x, ...others] = takeBackButtons();
    expect(x).toBeDefined();
    expect(others).toEqual([]);
    // The current transcript action strip keeps Send now and the X together in the row.
    expect(x!.closest(".cv-user__pending--beside")).toBeNull();
    await act(async () => {
      x!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      await settle();
    });
    const asked = daemon.requests.filter((request) => request.method === "_acpmux/queue_edit");
    expect(asked.map((request) => request.params)).toEqual([{ sessionId: CHAT, promptId: "p-steer", op: "withdraw" }]);
    expect(restored).toEqual(["Also keep the old flag working"]);

    // acpmux's record of it: the steer's bubble goes, the turn's prompt stays.
    await act(async () => {
      daemon.push(record([["mux", "steer_withdrawn", { promptId: "p-steer", turnId: "t-1" }]], 3));
      await settle();
    });
    const texts = rows()
      .filter((row) => row.kind === "user")
      .map((row) => row.text);
    expect(texts).toEqual(["Add retries"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a steer the agent read has no X", async () => {
  const { daemon, root, render } = await waitingSteer();
  try {
    await act(async () => {
      daemon.push(record([["mux", "user_message", { promptId: "p-next", text: "Then open a PR" }]], 3));
      await settle();
    });
    await render();
    expect(takeBackButtons()).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a steer whose attachments cannot be read stays, and nothing is withdrawn", async () => {
  const row = {
    id: "user-2",
    version: 1,
    kind: "user",
    text: "Use this",
    steer: "waiting",
    steerPromptId: "p-steer",
  } as const;
  const withdrawn: string[] = [];
  const restored: string[] = [];
  const took = await takeBackSteer(row as never, {
    withdraw: async (promptId) => (withdrawn.push(promptId), true),
    attachments: () => Promise.reject(new Error("acpmux has no image")),
    restore: (text) => restored.push(text),
  });
  expect([took, withdrawn, restored]).toEqual([false, [], []]);
});

test("a steer with an image acpmux could not give back stays", async () => {
  const row = {
    id: "user-2",
    version: 1,
    kind: "user",
    text: "Use this",
    steer: "waiting",
    steerPromptId: "p-steer",
    images: [{ id: "img-1" }],
  } as const;
  const withdrawn: string[] = [];
  const took = await takeBackSteer(row as never, {
    withdraw: async (promptId) => (withdrawn.push(promptId), true),
    attachments: async () => [],
    restore: () => {},
  });
  expect([took, withdrawn]).toEqual([false, []]);
});

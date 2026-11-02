// l10n-allow-file: test fixture prompts, not shipped UI.
// The X beside a steer the agent has not read yet (conversation/PendingSteer.tsx; Leo, 2026-10-21:
// "THERE'S A CANCEL AND EDIT BY CLICKING THE X BUTTON ON THE SENT MESSAGES TO CLAUDE.. THEY'RE
// STEERS BUT THEY HAVENT BEEN SENT SOMETIMES WITH THE TOOL CALLS AND WHATNOT WAITING"). A click
// asks acpmux to take the steer back (`_acpmux/queue_edit` `withdraw` for its promptId); once it
// did, its text goes back into the composer to edit, and its row goes with acpmux's
// `steer_withdrawn` record. A steer read already has no X, and one the agent read first stays.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { CHAT, connect, fakeDaemon, record, type Step } from "./support/agentPairDaemon";

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

/// A chat whose steer `promptId` waits; acpmux answers the X's first `refuses` withdraws false (the
/// agent took the steer already, or acpmux has not registered it yet while it prepares its images);
/// `lost` makes the withdraw fail on the way, unanswered.
async function waitingSteer({ promptId = "p-steer", refuses = 0, lost = false } = {}) {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { promptId: "p-turn", text: "Add retries" }],
      ["mux", "user_message", { promptId, text: "Also keep the old flag working", steer: true }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  const restored: string[] = [];
  let refusals = refuses;
  const actions = {
    unsteer: (row: Parameters<typeof takeBackSteer>[0]) =>
      takeBackSteer(row, {
        withdraw: (promptId) =>
          lost
            ? Promise.reject(new Error("socket closed"))
            : client
                .editQueued(promptId, { op: "withdraw" })
                .then((reply) => (refusals > 0 ? (refusals--, false) : reply?.ok === true)),
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
  expect([took, withdrawn, restored]).toEqual(["failed", [], []]);
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
  expect([took, withdrawn]).toEqual(["failed", []]);
});

const sendNow = () =>
  [...dom.window.document.querySelectorAll<HTMLButtonElement>("button.cv-user__send-now")].filter(
    (button) => button.textContent === translate("steer.sendNow"),
  );

// Leo, 2026-10-29: "Plus this fucking edit message thing. It doesn't even fucking work. And it fucking
// blinks with the fucking send now text." An X (its tooltip "Edit message") that acpmux refuses never
// does nothing: the row says the agent reads it after this step. acpmux also refuses for a moment
// right after a steer is sent (it registers the steer once its images are prepared), so the X stays,
// and a later click takes the steer back. Send now beside it is the same element throughout.
test("an X acpmux refuses says Read after this step and stays; a later click takes the steer back", async () => {
  const { daemon, restored, root, render } = await waitingSteer({ promptId: "p-refused", refuses: 1 });
  try {
    await render();
    const [before] = sendNow();
    expect(before).toBeDefined();
    const click = async () => {
      const [x] = takeBackButtons();
      await act(async () => {
        x!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
        await settle();
      });
    };
    await click();
    expect(daemon.requests.filter((request) => request.method === "_acpmux/queue_edit")).toHaveLength(1);
    expect(restored).toEqual([]);
    const pending = dom.window.document.querySelector(".cv-user__pending")!;
    expect(pending.querySelector(".cv-user__kept")?.textContent ?? null).toBe(translate("message.readAfterStep"));
    // Compared as counts and identities, not elements: a failing match prints no jsdom tree.
    expect(takeBackButtons().length).toBe(1);
    expect(takeBackButtons()[0]!.disabled).toBe(false);
    const [after] = sendNow();
    expect(after === before).toBe(true);
    expect(after?.disabled).toBe(false);
    // Drawn again (scrolled away and back) while acpmux still says it waits: the X is still offered.
    await act(async () => root.render(<></>));
    await render();
    expect(takeBackButtons().length).toBe(1);
    // acpmux has registered the steer now: the next click takes it back into the composer.
    await click();
    expect(daemon.requests.filter((request) => request.method === "_acpmux/queue_edit")).toHaveLength(2);
    expect(restored).toEqual(["Also keep the old flag working"]);
  } finally {
    await act(async () => root.unmount());
  }
});

// Review, 2026-10-29: a take-back that failed on the way (the withdraw never got its answer) is no
// refusal. The X stays to be tried again, and the row says nothing it does not know.
test("an X whose withdraw fails on the way stays to be tried again", async () => {
  const row = {
    id: "user-2",
    version: 1,
    kind: "user",
    text: "Use this",
    steer: "waiting",
    steerPromptId: "p-x",
  } as const;
  const lost = await takeBackSteer(row as never, {
    withdraw: () => Promise.reject(new Error("socket closed")),
    attachments: async () => [],
    restore: () => {},
  });
  const refused = await takeBackSteer(row as never, {
    withdraw: async () => false,
    attachments: async () => [],
    restore: () => {},
  });
  expect([lost, refused]).toEqual(["failed", "refused"]);

  const { daemon, root, render } = await waitingSteer({ promptId: "p-transient", lost: true });
  try {
    await render();
    const [x] = takeBackButtons();
    await act(async () => {
      x!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      await settle();
    });
    expect(daemon.requests.filter((request) => request.method === "_acpmux/queue_edit").length).toBe(0);
    expect(takeBackButtons().length).toBe(1);
    expect(takeBackButtons()[0]!.disabled).toBe(false);
    expect(dom.window.document.querySelector(".cv-user__kept") === null).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
});

// The running turn goes on under a waiting steer: the agent's current step runs its tools, call
// after call, before it reads the steer. Send now is never drawn again for it (a remount restarted
// its reveal: the blink).
const toolEvents = (count: number): Step[] =>
  Array.from({ length: count }, (_, index): Step => {
    const toolCallId = `call-${index >> 1}`;
    const update =
      index % 2 === 0
        ? {
            sessionUpdate: "tool_call",
            toolCallId,
            title: `Read src/file${index >> 1}.ts`,
            kind: "read",
            status: "in_progress",
          }
        : { sessionUpdate: "tool_call_update", toolCallId, status: "completed" };
    return ["in", update.sessionUpdate, { method: "session/update", params: { update } }];
  });

test("Send now keeps its element through 50 transcript events", async () => {
  const { daemon, root, render } = await waitingSteer({ promptId: "p-streaming" });
  try {
    await render();
    const [first] = sendNow();
    expect(first).toBeDefined();
    const events = toolEvents(50);
    for (const [index, event] of events.entries()) {
      await act(async () => {
        daemon.push(record([event], 3 + index));
        await settle();
      });
      await render();
      const [now, ...others] = sendNow();
      expect(others.length).toBe(0);
      expect(now === first).toBe(true);
    }
    expect(first!.isConnected).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
});

// The waiting steer's footer is drawn while it waits: no hover fade to restart and no dimming while
// the X or Send now is answered, either of which read as the blink.
test("a waiting steer's Send now and X are drawn with no fade and no dimming", () => {
  const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"), "utf8");
  const shown = css.match(/\.cv-user__actions:has\(\.cv-user__pending\)\s*\{([^}]*)\}/)?.[1] ?? "";
  expect(shown).toMatch(/opacity:\s*1\s*;/);
  expect(shown).toMatch(/transition:\s*none\s*;/);
  expect(css).not.toMatch(/\.cv-user__(send-now|take-back):disabled\s*\{[^}]*opacity/);
});

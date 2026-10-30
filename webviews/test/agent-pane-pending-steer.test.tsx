// l10n-allow-file: test fixture prompts, not shipped UI.
// Send now under a steer the agent has not read yet (conversation/PendingSteer.tsx): it shows only
// while the steer waits, and a click asks acpmux to stop the agent's current step with
// `_acpmux/queue_edit` `send_now` for that steer's own promptId, through the page's
// `chat.queue.edit` action. It never sends session/cancel: Send now does not end the turn.
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

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const sendNowButtons = () =>
  [...dom.window.document.querySelectorAll("button")].filter(
    (button) => button.textContent === translate("steer.sendNow"),
  );

test("Send now on a waiting steer asks queue_edit send_now for its promptId, and goes once it is read", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { promptId: "p-turn", text: "Add retries" }],
      ["mux", "user_message", { promptId: "p-steer", text: "Also keep the old flag working", steer: true }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  (dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => unknown> }).cmuxAcpmuxActions = {
    "chat.queue.edit": ({ promptId, ...edit }) => client.editQueued(String(promptId), edit),
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = () =>
    act(async () => root.render(<VirtualTranscript rows={rows()} onToggleActivity={() => {}} expanded={new Set()} />));
  try {
    await render();
    const [sendNow, ...others] = sendNowButtons();
    expect(sendNow).toBeDefined();
    expect(others).toEqual([]);
    // Send now leads the prompt's action row under the bubble (Leo, 2026-10-24): no clock, no
    // underline and nothing in the bubble's left gutter.
    const pending = sendNow!.closest(".cv-user__pending")!;
    expect(pending.classList.contains("cv-user__pending--beside")).toBe(false);
    // No clock: Send now is text alone. The row's only glyphs are its own icon buttons, Copy
    // (Leo, 2026-10-29: "i feel like im frequently missing the copy/whatever buttons on these
    // steers"; #27313, inside the row since #27256).
    const sendNowButton = pending.querySelector(".cv-user__send-now")!;
    expect(sendNowButton.querySelector("svg")).toBeNull();
    const copy = pending.querySelector(`button[aria-label="${translate("turn.copy")}"]`);
    expect(copy).not.toBeNull();
    expect(copy!.querySelector("svg")).not.toBeNull();
    const glyphs = [...pending.querySelectorAll("svg")];
    expect(glyphs.every((svg) => svg.closest("button.cv-iconbtn") !== null)).toBe(true);
    const actions = pending.parentElement!;
    expect(actions.classList.contains("cv-user__actions")).toBe(true);
    const bubble = actions.previousElementSibling!;
    expect(bubble.classList.contains("cv-user__bubble")).toBe(true);
    expect(bubble.textContent).toContain("Also keep the old flag working");
    expect(actions.firstElementChild).toBe(pending);
    const message = bubble.closest(".cv-user")!;
    // The bubble and its action row share one body, so the waiting controls stay attached to their
    // bubble (#27168); nothing else sits in the message, its left gutter included.
    expect([...message.children].map((child) => child.className)).toEqual(["cv-user__body"]);
    expect([...message.firstElementChild!.children].map((child) => child.className)).toEqual([
      "ui-glass cv-user__bubble selectable",
      "cv-user__actions",
    ]);
    await act(async () => {
      sendNow!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    const asked = daemon.requests.filter((request) => request.method === "_acpmux/queue_edit");
    expect(asked.map((request) => request.params)).toEqual([{ sessionId: CHAT, promptId: "p-steer", op: "send_now" }]);
    expect(daemon.requests.some((request) => request.method === "session/cancel")).toBe(false);

    // This daemon does not accept Send now, so the control stays until the agent reads it.
    expect(sendNowButtons()).toHaveLength(1);
    // A later prompt marks this steer read. Its queue controls disappear without a closing timer.
    await act(async () => {
      daemon.push(record([["mux", "user_message", { promptId: "p-next", text: "Then open a PR" }]], 3));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await render();
    expect(sendNowButtons()).toHaveLength(0);
    expect(message.querySelector(".cv-user__pending")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

// l10n-allow-file: test fixture prompts, not shipped UI.
// Prompts that failed one after another for the same cause share one failure line (Leo,
// 2026-10-21: Retry, Edit, Remove and Details repeated under every failed message). Each prompt
// keeps its bubble; the line sits under the last of the run, says how many it covers, and its
// actions act on all of them: Retry sends them again as one prompt, their texts in the order they
// were sent (the host allows one prompt per click, so one send each got only the first through),
// Edit puts them back in the composer in that order, Remove takes them all away. A failure with another cause, or
// a row between, starts a line of its own. The cause is the structured one (promptFailureCause.ts).
// Prompts acpmux never answered in time are never joined: acpmux may have taken them, so each keeps
// its own line, whose Retry sends it again under its own id (direct.ts retryPrompt, `resend`).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow, PromptDelivery } from "../src/agent-session/acpmux/model";

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

const START = Date.UTC(2026, 9, 21, 9, 0, 0);
let version = 0;
/// A prompt that did not get there, refused with `code` (or acpmux's `reason`).
const failed = (id: string, text: string, cause: Partial<PromptDelivery>): AcpmuxRow => ({
  id,
  version: ++version,
  at: START + version * 1000,
  kind: "user",
  text,
  failed: true,
  error: "Not sent.",
  delivery: {
    state: "failed",
    promptId: id.replace(/^local-/, ""),
    sessionId: "s",
    sentAt: START,
    failedAt: START + 10,
    hop: "acpmux",
    ...cause,
  },
});
const reply = (id: string, text: string): AcpmuxRow => ({
  id,
  version: ++version,
  at: START + version * 1000,
  kind: "assistant",
  text,
});
/// Refused for want of a gesture: acpmux never took it (the host refused it before it went).
const refused = { code: "transport.gesture_required" };
/// No answer from acpmux in time: acpmux may have taken it.
const timeout = { code: "timeout" };
const needsApp = { code: "transport.harness_not_confirmed" };

/// The transcript of `rows`, the page's actions recorded as [name, rowId], and the run's row ids
/// when an action takes the whole run.
async function draw(rows: AcpmuxRow[]) {
  const calls: unknown[][] = [];
  const record = (name: string) => (params: { rowId?: unknown; rowIds?: unknown }) =>
    void calls.push(params.rowIds === undefined ? [name, String(params.rowId)] : [name, String(params.rowId), params.rowIds]);
  (dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => unknown> }).cmuxAcpmuxActions = {
    "chat.retryPrompt": record("chat.retryPrompt"),
    "chat.editFailedPrompt": record("chat.editFailedPrompt"),
    "chat.removeFailedPrompt": record("chat.removeFailedPrompt"),
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () =>
    root.render(<VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} />),
  );
  const lines = () => [...dom.window.document.querySelectorAll(".cv-user__status--failed")];
  /// The row each failure line sits under.
  const lineRows = () => lines().map((line) => line.closest("[data-row-id]")?.getAttribute("data-row-id"));
  const click = async (label: string) => {
    const [line] = lines();
    const button = [...line!.querySelectorAll("button")].find((each) => each.textContent === label);
    if (!button) throw new Error(`no ${label} on the failure line`);
    await act(async () => {
      button.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
    });
  };
  return { calls, lines, lineRows, click, unmount: () => act(async () => root.unmount()) };
}

const prompts = () => [
  reply("a-0", "Added."),
  failed("local-p1", "Ship it", refused),
  failed("local-p2", "Ship it now", refused),
  failed("local-p3", "Please ship it", refused),
];

test("three prompts that failed for one cause share one line, under the last", async () => {
  const view = await draw(prompts());
  try {
    expect(view.lineRows()).toEqual(["local-p3"]);
    // Every prompt keeps its bubble.
    for (const text of ["Ship it", "Ship it now", "Please ship it"])
      expect(dom.window.document.body.textContent).toContain(text);
    const [line] = view.lines();
    expect(line!.textContent).toContain(translate("prompt.delivery.groupCount", { n: 3 }));
    const labels = [...line!.querySelectorAll("button")].map((button) => button.textContent);
    expect(labels).toEqual([
      translate("turn.retry"),
      translate("message.edit"),
      translate("prompt.delivery.remove"),
      translate("prompt.delivery.details"),
    ]);
  } finally {
    await view.unmount();
  }
});

const run = ["local-p1", "local-p2", "local-p3"];

test("the shared line's Retry sends the whole run once, in the order it was sent", async () => {
  const view = await draw(prompts());
  try {
    await view.click(translate("turn.retry"));
    // One action for the run: the page sends it as one prompt (direct.ts retryPrompts).
    expect(view.calls).toEqual([["chat.retryPrompt", "local-p3", run]]);
  } finally {
    await view.unmount();
  }
});

test("Edit puts every prompt back in the composer in order, and Remove takes them all away", async () => {
  const edit = await draw(prompts());
  try {
    await edit.click(translate("message.edit"));
    // One action for the run: the page takes it back as one text, in order (direct.ts takeFailedPrompts).
    expect(edit.calls).toEqual([["chat.editFailedPrompt", "local-p3", run]]);
  } finally {
    await edit.unmount();
  }
  const remove = await draw(prompts());
  try {
    await remove.click(translate("prompt.delivery.remove"));
    expect(remove.calls.map(([name]) => name)).toEqual(Array(3).fill("chat.removeFailedPrompt"));
    expect(remove.calls.map(([, row]) => row)).toEqual(run);
  } finally {
    await remove.unmount();
  }
});

test("another cause, or a row between, starts a line of its own", async () => {
  const view = await draw([
    failed("local-p1", "Ship it", refused),
    failed("local-p2", "Switch to the new harness", needsApp),
    failed("local-p3", "Switch to it again", needsApp),
    reply("a-1", "Which harness?"),
    failed("local-p4", "Ship it now", refused),
  ]);
  try {
    expect(view.lineRows()).toEqual(["local-p1", "local-p3", "local-p4"]);
    const [single, pair] = view.lines();
    // A line for one prompt says no count.
    expect(single!.textContent).not.toContain(translate("prompt.delivery.groupCount", { n: 1 }));
    expect(pair!.textContent).toContain(translate("prompt.delivery.groupCount", { n: 2 }));
  } finally {
    await view.unmount();
  }
});

test("prompts acpmux never answered keep a line each, whose Retry sends that prompt alone", async () => {
  const view = await draw([
    reply("a-0", "Added."),
    failed("local-p1", "Ship it", timeout),
    failed("local-p2", "Ship it now", timeout),
    failed("local-p3", "Please ship it", timeout),
  ]);
  try {
    expect(view.lineRows()).toEqual(run);
    for (const line of view.lines())
      expect(line.textContent).not.toContain(translate("prompt.delivery.groupCount", { n: 3 }));
    await view.click(translate("turn.retry"));
    // The row on its own, no run: the page sends it again under its prompt id with `resend`.
    expect(view.calls).toEqual([["chat.retryPrompt", "local-p1"]]);
  } finally {
    await view.unmount();
  }
});

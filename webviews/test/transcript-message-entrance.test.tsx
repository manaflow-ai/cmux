// l10n-allow-file: the transcript fixture text is test data, not shipped UI.
// New prompts and replies get one entrance class when their row first arrives. A later streamed
// version of the same row must not replay that entrance, and the existing rows stay mounted.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

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
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: "user" | "assistant", text: string, version = 1): AcpmuxRow => ({
  id,
  kind,
  text,
  version,
  at: 1,
});

test("new user and assistant rows enter once, while streamed versions stay still", async () => {
  const Row = ({ row: item }: { row: AcpmuxRow }) =>
    item.incoming?.kind === "hidden" ? null : <div data-testid={`content-${item.id}`}>{item.text}</div>;
  const registry = { user: Row, assistant: Row } as never;
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (rows: AcpmuxRow[]) =>
    act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          registry={registry}
          sessionId="entrance-session"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  try {
    const existing = [row("prompt-1", "user", "Earlier prompt"), row("reply-1", "assistant", "Earlier reply")];
    await render(existing);
    await render([...existing, row("prompt-2", "user", "New prompt")]);
    const prompt = dom.window.document.querySelector<HTMLElement>('[data-row-id="prompt-2"]');
    expect(prompt?.classList.contains("acpmux-row--message-enter")).toBe(true);
    await render([...existing, row("prompt-2", "user", "New prompt"), row("reply-2", "assistant", "First token", 1)]);
    const promptNode = dom.window.document.querySelector<HTMLElement>('[data-row-id="prompt-2"]');
    const replyNode = dom.window.document.querySelector<HTMLElement>('[data-row-id="reply-2"]');
    expect(promptNode).toBeTruthy();
    expect(replyNode).toBeTruthy();
    const promptPresentation = promptNode!.querySelector<HTMLElement>(".acpmux-row__message-presentation");
    const replyPresentation = replyNode!.querySelector<HTMLElement>(".acpmux-row__message-presentation");
    expect(promptPresentation).toBeTruthy();
    expect(replyPresentation).toBeTruthy();
    const promptEntered = promptNode!.classList.contains("acpmux-row--message-enter");
    const replyEntered = replyNode!.classList.contains("acpmux-row--message-enter");
    expect(promptEntered).toBe(true);
    expect(replyEntered).toBe(true);
    await render([
      ...existing,
      row("prompt-2", "user", "New prompt"),
      row("reply-2", "assistant", "First token and another token", 2),
    ]);
    const promptAfter = dom.window.document.querySelector<HTMLElement>('[data-row-id="prompt-2"]');
    const replyAfter = dom.window.document.querySelector<HTMLElement>('[data-row-id="reply-2"]');
    const promptPresentationAfter = promptAfter?.querySelector<HTMLElement>(".acpmux-row__message-presentation");
    const replyPresentationAfter = replyAfter?.querySelector<HTMLElement>(".acpmux-row__message-presentation");
    expect(promptAfter).toBe(promptNode);
    expect(replyAfter).toBe(replyNode);
    expect(promptPresentationAfter).toBe(promptPresentation);
    expect(replyPresentationAfter).toBe(replyPresentation);
    expect(promptAfter?.classList.contains("acpmux-row--message-enter")).toBe(promptEntered);
    expect(replyAfter?.classList.contains("acpmux-row--message-enter")).toBe(replyEntered);

    const hidden = { ...row("hidden-1", "user", ""), incoming: { kind: "hidden" as const } };
    await render([...existing, hidden]);
    const hiddenNode = dom.window.document.querySelector<HTMLElement>('[data-row-id="hidden-1"]');
    expect(hiddenNode?.matches(":empty")).toBe(true);
    expect(hiddenNode?.querySelector(".acpmux-row__message-presentation")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

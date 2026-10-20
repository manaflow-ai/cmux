import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

/// Opening Chat summary (Thread details) after it was hidden drew more hooks than the hidden card
/// did, and React took the whole pane down (Lucas 2026-10-18).
test("the summary card opens after being hidden without breaking the pane", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { SummaryCard } = await import("../src/agent-session/acpmux/summary/SummaryCard");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  const errors: unknown[] = [];
  const card = (shown: boolean) => ({
    shown,
    column: false,
    reserve: false,
    collapsed: false,
    toggle() {},
    show() {},
    close() {},
    fold() {},
  });
  const draw = (shown: boolean) => (
    <UiProvider container={rootElement}>
      <SummaryCard
        card={card(shown)}
        rows={[]}
        subagents={{ views: undefined, current: undefined, asks: new Set(), onOpen() {} }}
      />
    </UiProvider>
  );
  const onError = (error: unknown) => errors.push(error);
  const saved = console.error;
  console.error = onError;
  try {
    await act(async () => root.render(draw(false)));
    await act(async () => root.render(draw(true)));
  } finally {
    console.error = saved;
  }
  expect(errors.filter((error) => String(error).includes("hooks"))).toEqual([]);
  expect(rootElement.textContent).not.toBe("");
  await act(async () => root.unmount());
});

for (const column of [false, true]) {
  for (const dismiss of ["button", "Escape"]) {
    test(`Thread details ${column ? "column" : "popover"} closes with ${dismiss} and focuses its header button`, async () => {
      const { act } = await import("react");
      const { createRoot } = await import("react-dom/client");
      const { UiProvider } = await import("../src/ui/UiProvider");
      const { SummaryCard } = await import("../src/agent-session/acpmux/summary/SummaryCard");
      const { SummaryButton } = await import("../src/agent-session/acpmux/summary/SummaryButton");
      const { useSummaryCard, resetSummaryCards } = await import("../src/agent-session/acpmux/summary/cardState");
      const { translate } = await import("../src/agent-session/acpmux/i18n");
      resetSummaryCards();
      const element = dom.window.document.getElementById("root")!;
      const root = createRoot(element);
      function Pane() {
        const card = useSummaryCard(column, false);
        const panel = (
          <SummaryCard
            card={card}
            rows={[]}
            subagents={{ views: undefined, current: undefined, asks: new Set(), onOpen() {} }}
          />
        );
        return (
          <div className="acpmux-shell">
            <div className="acpmux-stage">
              <SummaryButton card={card} />
              {!column && panel}
            </div>
            {column && panel}
          </div>
        );
      }
      try {
        await act(async () =>
          root.render(
            <UiProvider container={element}>
              <Pane />
            </UiProvider>,
          ),
        );
        const opener = element.querySelector<HTMLButtonElement>(".acpmux-summary-button")!;
        opener.focus();
        await act(async () => opener.click());
        const close = element.querySelector<HTMLButtonElement>(".acpmux-summary-card__close");
        expect(close).not.toBeNull();
        expect(close!.getAttribute("aria-label")).toBe(translate("image.close"));
        expect(dom.window.document.activeElement).toBe(close!);
        await act(async () => {
          if (dismiss === "button") close!.click();
          else
            close!.dispatchEvent(
              new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
            );
        });
        expect(element.querySelector(".acpmux-summary-card:not([aria-hidden])")).toBeNull();
        expect(dom.window.document.activeElement).toBe(opener);
      } finally {
        await act(async () => root.unmount());
        resetSummaryCards();
      }
    });
  }
}

test("opening Files after a fresh chat becomes a column clears its earlier popover choice", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { useSummaryCard, resetSummaryCards } = await import("../src/agent-session/acpmux/summary/cardState");
  const { openViewer } = await import("../src/agent-session/acpmux/chatViewerPanels");
  type Card = ReturnType<typeof useSummaryCard>;
  let card: Card;
  function Pane({ column }: { column: boolean }) {
    card = useSummaryCard(column, true);
    return <output>{card.shown ? "shown" : "hidden"}</output>;
  }
  resetSummaryCards();
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () => root.render(<Pane column={false} />));
    await act(async () => card.show());
    await act(async () => root.render(<Pane column />));
    expect(card!.shown).toBe(true);
    await act(async () => openViewer(card, () => root.render(<Pane column={false} />)));
    expect(card!.shown).toBe(false);
    await act(async () => root.render(<Pane column />));
    expect(card!.shown).toBe(false);
    // An explicit reopen in an empty/narrow view must also reopen the later column.
    await act(async () => root.render(<Pane column={false} />));
    await act(async () => card.show());
    await act(async () => root.render(<Pane column />));
    expect(card!.shown).toBe(true);
  } finally {
    await act(async () => root.unmount());
    resetSummaryCards();
  }
});

test("summary content arriving automatically leaves composer focus alone", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { SummaryCard } = await import("../src/agent-session/acpmux/summary/SummaryCard");
  const { useSummaryCard, resetSummaryCards } = await import("../src/agent-session/acpmux/summary/cardState");
  resetSummaryCards();
  const element = dom.window.document.getElementById("root")!;
  const composer = dom.window.document.createElement("button");
  dom.window.document.body.append(composer);
  composer.focus();
  const root = createRoot(element);
  function Pane({ hasContent }: { hasContent: boolean }) {
    const card = useSummaryCard(true, hasContent);
    return (
      <SummaryCard
        card={card}
        rows={[]}
        subagents={{ views: undefined, current: undefined, asks: new Set(), onOpen() {} }}
      />
    );
  }
  try {
    await act(async () =>
      root.render(
        <UiProvider container={element}>
          <Pane hasContent={false} />
        </UiProvider>,
      ),
    );
    await act(async () =>
      root.render(
        <UiProvider container={element}>
          <Pane hasContent />
        </UiProvider>,
      ),
    );
    expect(element.querySelector(".acpmux-summary-card__close")).not.toBeNull();
    expect(dom.window.document.activeElement).toBe(composer);
  } finally {
    await act(async () => root.unmount());
    composer.remove();
    resetSummaryCards();
  }
});

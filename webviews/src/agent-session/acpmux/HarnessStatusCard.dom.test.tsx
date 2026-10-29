import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "./model";
import { HarnessStatusCard } from "./HarnessStatusCard";
import { SummaryCard } from "./summary/SummaryCard";
import { PreviewCard } from "./threadMinimap/PreviewCard";
import { useEscapeCloses } from "../../ui/escapeDismiss";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "IS_REACT_ACT_ENVIRONMENT",
    "__cmuxPaneStrings",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // The card's labels are pane strings (its row labels too): keep the preloaded English table.
  const preloaded = saved.get("__cmuxPaneStrings") as Record<string, Record<string, string>> | undefined;
  globalThis.__cmuxPaneStrings = {
    en: { ...preloaded?.en, "turn.copy": "Copy", "turn.copied": "Copied", "status.copyAll": "Copy all" },
  };
  return dom.window.document.getElementById("root")!;
}

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

const summary = (): NonNullable<AcpmuxSnapshot["summary"]> => ({
  sessionId: "session-123",
  cwd: "/Users/leo/cmux",
  host: "build-box",
  model: "claude-sonnet-5-5",
  effort: "high",
  harness: "claude",
  agentInfo: { version: "2.1.309", authSource: "managed login" },
});

async function render(onDismiss = () => {}) {
  const container = installDom();
  const copied: string[] = [];
  Object.defineProperty(dom!.window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (value: string) => copied.push(value) },
  });
  await act(async () => {
    root = createRoot(container);
    root.render(<HarnessStatusCard summary={summary()} rows={[]} onDismiss={onDismiss} />);
  });
  return { container, copied };
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
    });
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a value copies without replacing its selectable text, and Copy all uses label-value lines", async () => {
  const { container, copied } = await render();
  const session =
    container.querySelector<HTMLElement>('[data-copy-label="Session"]') ??
    container.querySelector<HTMLElement>(".acpmux-harness-status__value");
  expect(session?.textContent).toContain("session-123");
  await act(async () => session!.click());
  await settle();
  expect(copied[0]).toBe("session-123");
  expect(session!.textContent).toContain("session-123");
  expect(session!.textContent).toContain("Copied");

  const copyAll = container.querySelector<HTMLButtonElement>(".acpmux-harness-status__copy-all")!;
  expect(copyAll.getAttribute("aria-label")).toBe("Copy all");
  await act(async () => copyAll.click());
  await settle();
  expect(copyAll.getAttribute("aria-label")).toBe("Copied");
  expect(copyAll.querySelector('[aria-hidden="false"]')?.textContent).toBe("Copied");
  expect(copied.at(-1)).toContain("Session: session-123");
  expect(copied.at(-1)).toContain("CWD: /Users/leo/cmux");
});

test("a non-collapsed selection inside a value remains a partial-copy gesture", async () => {
  const { container, copied } = await render();
  const value = container.querySelector<HTMLElement>(".acpmux-harness-status__value-text")!;
  const selection = dom!.window.getSelection()!;
  const range = dom!.window.document.createRange();
  range.setStart(value.firstChild!, 0);
  range.setEnd(value.firstChild!, 4);
  selection.removeAllRanges();
  selection.addRange(range);
  await act(async () => value.parentElement!.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true })));
  await settle();
  expect(copied).toEqual([]);
});

test("Escape dismisses the card from composer focus, while an open menu gets first refusal", async () => {
  const dismissed: string[] = [];
  await render(() => dismissed.push("closed"));
  const composer = document.createElement("input");
  document.body.append(composer);
  composer.focus();
  const composerEscapes: string[] = [];
  composer.addEventListener("keydown", () => composerEscapes.push("stop"));
  const quickEscapes: string[] = [];
  const quickEscape = () => quickEscapes.push("dismiss");
  document.addEventListener("keydown", quickEscape);
  const first = new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
  composer.dispatchEvent(first);
  expect(first.defaultPrevented).toBe(true);
  expect(dismissed).toEqual(["closed"]);
  expect(composerEscapes).toEqual([]);
  expect(quickEscapes).toEqual([]);
  document.removeEventListener("keydown", quickEscape);

  // Re-mount the card, then leave an interactive AnchoredCard open. Tooltip popups use role=dialog
  // without an [open] attribute, so the status card must defer to the real overlay shape.
  await act(async () =>
    root!.render(<HarnessStatusCard summary={summary()} rows={[]} onDismiss={() => dismissed.push("menu-closed")} />),
  );
  const popover = document.createElement("div");
  popover.setAttribute("role", "dialog");
  popover.className = "ui-tooltip ui-card ui-glass";
  document.body.append(popover);
  const second = new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
  document.dispatchEvent(second);
  expect(second.defaultPrevented).toBe(false);
  expect(dismissed).toEqual(["closed"]);
  popover.remove();
  composer.remove();
});

test("a closed or hidden overlay retained for its fade no longer claims Escape", async () => {
  const dismissed: string[] = [];
  await render(() => dismissed.push("closed"));
  const overlay = document.createElement("div");
  overlay.setAttribute("role", "dialog");
  overlay.className = "ui-dialog";
  document.body.append(overlay);
  for (const state of ["data-closed", "data-ending-style", "hidden", "inert"]) {
    overlay.setAttribute(state, "");
    const event = new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    document.dispatchEvent(event);
    expect(event.defaultPrevented).toBe(true);
    overlay.removeAttribute(state);
  }
  expect(dismissed).toHaveLength(4);
  overlay.remove();
});

test("the real Summary popover takes Escape before status, while the inline Summary does not", async () => {
  const dismissed: string[] = [];
  const container = installDom();
  function Cards({ column = false }: { column?: boolean }) {
    const [shown, setShown] = useState(true);
    return (
      <>
        <HarnessStatusCard summary={summary()} rows={[]} onDismiss={() => dismissed.push("status")} />
        <SummaryCard
          rows={[]}
          subagents={{ views: undefined, current: undefined, asks: new Set(), onOpen: () => {} }}
          card={{
            shown,
            column,
            reserve: false,
            collapsed: true,
            show: () => {},
            close: () => setShown(false),
            toggle: () => {},
            fold: () => {},
          }}
        />
      </>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Cards />);
  });
  expect(container.querySelector('.acpmux-summary-card[data-placement="popover"]')).not.toBeNull();
  await act(async () =>
    document.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    ),
  );
  expect(dismissed).toEqual([]);
  expect(container.querySelector('.acpmux-summary-card[data-placement="popover"]')).toBeNull();
  await act(async () =>
    document.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    ),
  );
  expect(dismissed).toEqual(["status"]);
  await act(async () => root!.render(<Cards key="inline" column />));
  expect(container.querySelector('.acpmux-summary-card[data-placement="inline"]')).not.toBeNull();
  await act(async () =>
    document.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    ),
  );
  expect(dismissed).toEqual(["status", "status"]);
});

test("the focused real minimap preview takes Escape before status", async () => {
  const dismissed: string[] = [];
  const container = installDom();
  function Cards() {
    const [shown, setShown] = useState(true);
    const [focused, setFocused] = useState(false);
    useEscapeCloses(shown && focused, () => setShown(false));
    return (
      <>
        <HarnessStatusCard summary={summary()} rows={[]} onDismiss={() => dismissed.push("status")} />
        {shown && (
          <PreviewCard
            id="preview"
            x={0}
            y={0}
            prompt="Test prompt"
            reply={[]}
            bookmark={{ marked: false, toggle: () => {} }}
            onPointerLeave={() => {}}
            onFocus={() => setFocused(true)}
          />
        )}
      </>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Cards />);
  });
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-minimap__bookmark")!.focus());
  await act(async () =>
    document.activeElement!.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    ),
  );
  expect(dismissed).toEqual([]);
  expect(container.querySelector(".acpmux-minimap__card")).toBeNull();
});

// The chat header's top strip as Claude Code desktop draws it (Leo 2026-10-21: "why do you still have
// this spacing and these separators"): no separators between the tools, and one glyph size
// (HEADER_GLYPH) for every icon button: the quick actions, the summary button, the "..." menu, the
// Needs you inbox and Session Info toggle. header.css gives them one 24px square on a 26px pitch;
// the gallery's grouped-controls play measures that in a real browser.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the header strip has no separators and every icon button draws the same glyph size", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools, HEADER_GLYPH } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  const { NeedsYouButton } = await import("../src/agent-session/acpmux/needsYou/NeedsYou");
  const { SummaryButton } = await import("../src/agent-session/acpmux/summary/SummaryButton");
  // Every quick action as a button, so each one's glyph is measured.
  configureQuickActions({
    quickActions: ["changes", "preview", "files", "terminal", "splitDown", "browser", "newTab"],
  });
  const noop = () => {};
  const card = { shown: false, column: false, toggle: noop, show: noop, hide: noop };
  root = createRoot(host);
  act(() =>
    root!.render(
      <header className="acpmux-header">
        <div className="acpmux-handoff-header-tools">
          <ChatHeaderTools
            onTerminal={noop}
            onSplitDown={noop}
            onBrowser={noop}
            hasChanges
            onChanges={noop}
            onFiles={noop}
            previewUrl="http://localhost:5173/"
            onPreview={noop}
            onSideTabs={noop}
            summary={<SummaryButton card={card as never} />}
            menu={() => [{ key: "rename", label: "Rename", icon: "action.edit" }]}
            inbox={
              <NeedsYouButton
                items={[]}
                actions={{ answer: async () => undefined, goTo: noop, ask: async () => undefined }}
              />
            }
          />
        </div>
      </header>,
    ),
  );
  expect(host.querySelector("hr, [role=separator], .acpmux-header-separator")).toBeNull();
  const buttons = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-header button")];
  expect(buttons.map((button) => button.getAttribute("aria-label"))).toEqual([
    // The right-side panel's toggle leads the top-right icons, as in Claude and ChatGPT desktop, even
    // ahead of the Needs you inbox.
    "Chat summary",
    "Needs you",
    "Changes",
    "Preview",
    "Files",
    "Terminal",
    "Split Down",
    "Browser",
    "New tab",
    "Chat actions",
  ]);
  expect(buttons[0]?.querySelector("svg")?.getAttribute("data-icon")).toBe("view.list");
  for (const button of buttons) {
    expect(button.classList.contains("acpmux-header-tool")).toBe(true);
    const glyph = button.querySelector("svg");
    expect([button.getAttribute("aria-label"), glyph?.getAttribute("width")]).toEqual([
      button.getAttribute("aria-label"),
      String(HEADER_GLYPH),
    ]);
  }
  act(() => configureQuickActions({}));
});

test("the compact chat tools use host SF Symbols, with overflow last and no duplicate terminal", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { PanelToggle } = await import("../src/agent-session/acpmux/header/PanelToggle");
  const { setHarnessSymbolHost } = await import("../src/agent-session/shared/harnessIcons");
  const requested: string[] = [];
  const template = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB";
  root ??= createRoot(host);
  await act(async () => {
    setHarnessSymbolHost(async (symbol) => {
      requested.push(symbol);
      return template;
    });
    root!.render(
      <ChatHeaderTools
        onTerminal={() => {}}
        onBrowser={() => {}}
        onChanges={() => {}}
        hasChanges
        summary={<PanelToggle label="Session Info" shown onToggle={() => {}} />}
        menu={() => []}
      />,
    );
  });
  expect(requested.sort()).toEqual(["ellipsis", "globe", "list.bullet", "plusminus", "terminal"]);
  const buttons = [...host.querySelectorAll(".acpmux-header-tool")];
  expect(buttons.map((button) => button.getAttribute("aria-label"))).toEqual([
    "Session Info",
    "Changes",
    "Terminal",
    "Browser",
    "Chat actions",
  ]);
  for (const button of buttons) {
    const glyph = button.querySelector<HTMLElement>("[data-symbol]")!;
    expect(glyph).not.toBeNull();
    expect(glyph.getAttribute("aria-hidden")).toBe("true");
    expect(glyph.style.width).toBe("16px");
    expect(glyph.style.height).toBe("16px");
    expect(glyph.style.mask).toContain(template);
    expect(glyph.style.color).toBe(
      button.getAttribute("aria-pressed") === "true" ? "var(--agent-lit-glyph, var(--agent-accent))" : "",
    );
  }
  await act(async () => root!.render(<PanelToggle label="Session Info" shown={false} onToggle={() => {}} />));
  const unpressed = host.querySelector<HTMLElement>("[data-symbol]")!;
  expect(unpressed.dataset.symbol).toBe("list.bullet");
  expect(unpressed.style.color).toBe("");
  act(() => {
    setHarnessSymbolHost(undefined);
  });
});

// l10n-allow-file: test fixtures.
// A started chat restored after an app restart: the composer's access chip, once it has named the
// chat's mode ("Bypass permissions"), is never removed, blanked or renamed to the placeholder while
// the chat loads; it may only change to the mode the session itself reports. The report: "the bypass
// permissions appears then disappears after it loaded in."
//
// The frames are the summaries the pane hands ComposerPickers on that path (direct.ts):
//   1. the kept tail (`drawKeptTail`, `{...kept.summary, ...listed}`): the detail last read, modes
//      included;
//   2. the listed row as the summary (`seedListedSummary`, direct.ts ~8341, called at ~14232 when
//      no kept tail drew: none kept, older than shown, or a tail with no transcript rows):
//      acpmux's list row names `currentModeId` but carries no `modes`, so the published summary
//      (`publishedSummary` ~11947, liveModes) has none;
//   3. the chat selected with no summary yet (`opening`, ComposerPickers ~749): a reset
//      (`resetSessionState`) between the tail and the attach;
//   4. the attach's detail, modes included.
// Each frame is drawn as the pane draws it: through shownChrome.ts, which keeps the chrome the page
// showed until the attach answers. (Test first written by the pane-load-everywhere lane, where it
// failed on frames 2 and 3.)
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  const { setStartModeSource, resetStartModesForTests } = await import("../src/agent-session/acpmux/startMode");
  setStartModeSource(undefined);
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  resetStartModesForTests();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const CHAT = "chat-restored";
const MODES = [
  { id: "default", name: "Ask before edits" },
  { id: "acceptEdits", name: "Accept edits" },
  { id: "bypassPermissions", name: "Bypass permissions" },
];

/// acpmux's list row for the chat (sessionList.ts `sessionEntry` keeps no mode).
const listed = { sessionId: CHAT, harness: "claude", model: "claude-opus-5-5", effort: "high", cwd: "/repo" };

/// The detail as the pane publishes it: a started chat (turns sent) on this Mac.
const detail = (currentModeId: string) => ({
  sessionId: CHAT,
  harness: "claude",
  family: "claude",
  cwd: "/repo",
  model: "claude-opus-5-5",
  turnCount: 6,
  modes: { currentModeId, availableModes: MODES },
});

/// The listed row as the summary (seedListedSummary): no `modes`, its `currentModeId` dropped by
/// publishedSummary (liveModes keeps modes only when there are some).
const seeded = () => {
  const { modes: _modes, ...rest } = detail("bypassPermissions");
  return { ...rest, modes: undefined };
};

type Frame = { label: string; summary: Record<string, unknown> | undefined; connection?: string };

async function render(summary: Record<string, unknown> | undefined) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const catalog = BUNDLED_MODEL_CATALOG.harnesses.map((entry) => ({
    id: entry.id,
    name: entry.name,
    family: entry.families[0],
    models: entry.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [listed],
    sessionId: CHAT,
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary,
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" });
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
        harnessesListed
      />
    );
  }
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    );
  });
}

/// The access chip's label; null when the row draws no access chip.
const accessLabel = () => {
  const chip = host.querySelector<HTMLElement>(".acpmux-mode");
  return chip ? (chip.querySelector(".acpmux-mode-text")?.textContent ?? "").trim() : null;
};

/// Draws each frame in turn, as App.tsx does (through `shownChrome().keep`), and returns what the
/// chip said in each.
async function play(frames: Frame[]): Promise<{ label: string; shown: string | null }[]> {
  const { shownChrome } = await import("../src/agent-session/acpmux/shownChrome");
  const { emptySnapshot } = await import("../src/agent-session/acpmux/snapshotCache");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const chrome = shownChrome();
  let previous: Snapshot | undefined;
  const seen: { label: string; shown: string | null }[] = [];
  for (const frame of frames) {
    const given = {
      ...emptySnapshot(),
      sessionId: CHAT,
      connection: frame.connection ?? "connecting",
      summary: frame.summary,
    } as unknown as Snapshot;
    previous = chrome.keep(previous, given);
    await render(previous.summary as Record<string, unknown> | undefined);
    seen.push({ label: frame.label, shown: accessLabel() });
  }
  return seen;
}

test("a restored started chat's mode chip never goes or turns into the placeholder while the chat loads", async () => {
  // A Mac that has started many Claude chats in full access: acpmux's kept start-mode answers.
  const { rememberStartMode } = await import("../src/agent-session/acpmux/startMode");
  rememberStartMode("claude", "/repo", { modeId: "bypassPermissions", name: "Bypass permissions" });
  rememberStartMode("claude", undefined, { modeId: "bypassPermissions", name: "Bypass permissions" });

  const seen = await play([
    { label: "kept tail drawn", summary: detail("bypassPermissions") },
    { label: "listed row seeded (no kept tail)", summary: seeded() },
    { label: "selected, summary reset (opening)", summary: undefined },
    { label: "attach detail", summary: detail("bypassPermissions"), connection: "attached" },
    // acpmux drops `modes` first from a reply too big to send (hub/paging.rs).
    {
      label: "a later detail without modes",
      summary: { ...detail("bypassPermissions"), modes: null },
      connection: "session changed",
    },
  ]);
  // The first frame names the chat's mode.
  expect(seen[0]?.shown).toBe("Bypass permissions");
  // Every later frame: the same name (the session reports no other mode on this path).
  expect(seen).toEqual(seen.map(({ label }) => ({ label, shown: "Bypass permissions" })));
});

test("the chip may change only to the mode the session itself reports", async () => {
  const seen = await play([
    { label: "kept tail drawn", summary: detail("bypassPermissions") },
    { label: "listed row seeded (no kept tail)", summary: seeded() },
    { label: "attach detail, session now in Ask before edits", summary: detail("default"), connection: "attached" },
  ]);
  expect(seen[0]?.shown).toBe("Bypass permissions");
  // Between the tail and the attach the chip holds the mode it named; the attach's own mode then
  // replaces it in place ("Manual" is Claude Code's own label for `default`, harnessModes.ts).
  expect(seen[1]).toEqual({ label: "listed row seeded (no kept tail)", shown: "Bypass permissions" });
  expect(seen[2]?.shown).toBe("Manual");
});

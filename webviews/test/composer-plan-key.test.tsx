import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  for (const [key, value] of Object.entries({
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    KeyboardEvent: window.KeyboardEvent,
    MouseEvent: window.MouseEvent,
    InputEvent: window.InputEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    localStorage: window.localStorage,
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});
afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

/// A started chat on an agent whose modes are Ask, Accept Edits and Plan, in `currentModeId`.
function chat(currentModeId: string): AcpmuxSnapshot {
  const sessionId = "composer-plan-key";
  return noChat([], {
    sessionId,
    summary: {
      sessionId,
      harness: "chipfake",
      cwd: "/repo",
      turnCount: 1,
      modes: {
        currentModeId,
        availableModes: [
          { id: "default", name: "Ask" },
          { id: "acceptEdits", name: "Accept Edits" },
          { id: "plan", name: "Plan" },
        ],
      },
    },
  });
}

async function draw(snapshot: AcpmuxSnapshot, onMode: (modeId: string) => void) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={snapshot.sessionId}
        chips={() => null}
        onSend={() => true}
        onStop={() => {}}
        onMode={onMode}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[]}
      />,
    ),
  );
}

// Fleet check 2026-11-20: Toggle Plan Mode (Ctrl-Opt-Cmd-P) ran its page command
// (`composer.togglePlan`, composerControls.ts) and the chat's composer sent no session/set_mode. The
// + menu registered its Plan opener with a useEffectEvent function, and React 19.2.3 updates those only
// in a plain function component (react-dom commitBeforeMutationEffects: tag 0; memo and forwardRef
// skip it): the memo'd menu kept its first render's, drawn before a new chat's agent reported its
// modes, which ran no Plan row.
test("Toggle Plan Mode's page command switches the chat's composer into Plan and back", async () => {
  const { openComposerControl } = await import("../src/agent-session/acpmux/composerControls");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const picked: string[] = [];
  await draw(chat("default"), (modeId) => void picked.push(modeId));
  await act(async () => void openComposerControl("togglePlan", translate));
  expect(picked).toEqual(["plan"]);
  await draw(chat("plan"), (modeId) => void picked.push(modeId));
  await act(async () => void openComposerControl("togglePlan", translate));
  expect(picked).toEqual(["plan", "default"]);
});

test("Toggle Plan Mode works in a chat whose agent reported its modes after the composer drew", async () => {
  const { openComposerControl } = await import("../src/agent-session/acpmux/composerControls");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const picked: string[] = [];
  const starting = chat("default");
  await draw(
    { ...starting, summary: { ...starting.summary!, modes: undefined } },
    (modeId) => void picked.push(modeId),
  );
  await draw(chat("default"), (modeId) => void picked.push(modeId));
  await act(async () => void openComposerControl("togglePlan", translate));
  expect(picked).toEqual(["plan"]);
});

test("a toolbar button invokes this chat's plan action and omits unavailable actions", async () => {
  const { MockAppPanelsClient } = await import("../src/apps/scene/panelsMock");
  const { appPanelsDevClient, installAppPanelsDevClient } = await import("../src/apps/scene/panelsClient");
  const previous = appPanelsDevClient();
  const client = new MockAppPanelsClient();
  client.toolbarButtons = [
    { action: "composer.planMode", label: "Change plan mode" },
    { action: "unavailable.action", label: "Missing action" },
  ];
  installAppPanelsDevClient(client);
  try {
    const picked: string[] = [];
    await draw(chat("default"), (modeId) => void picked.push(modeId));
    const button = host.querySelector<HTMLButtonElement>('button[aria-label="Change plan mode"]');
    expect(button).toBeTruthy();
    expect(host.querySelector('[aria-label="Missing action"]')).toBeNull();
    await act(async () => button!.click());
    expect(picked).toEqual(["plan"]);
  } finally {
    installAppPanelsDevClient(previous);
  }
});

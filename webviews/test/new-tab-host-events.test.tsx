// On the shared page host the agent page's New Tab places and weather arrive as host events
// (`cmux.agent.host.events`, kinds `newTabPlaces` and `newTabWeather`), not as host scripts: a host
// script thawed a frozen hidden New Tab page on every terminal title change (perf-lead.md F3,
// PATTERNS.md P10), while a host event waits folded in the host and goes at the thaw. The page
// takes each one in place, as it takes the old host's `acpmux-newtab-places` and
// `acpmux-newtab-weather` events.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "CustomEvent",
  "Event",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    CustomEvent: window.CustomEvent,
    Event: window.Event,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("newTabPlaces and newTabWeather host events reach the shown New Tab page in place", async () => {
  const { createRoot } = await import("react-dom/client");
  const { newTabHost } = await import("../src/agent-session/acpmux/NewTabPage");
  const { useNewTabPlaces, useNewTabWeather } = await import("../src/agent-session/acpmux/newtab/adoption");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  type Host = ReturnType<typeof newTabHost>;
  let shown: Host | undefined;
  function Page() {
    const [page, setPage] = useState<Host>(() =>
      newTabHost({ newTab: { layout: "a", kind: "agent", omnibar: { tabs: [], workspaces: [] } } }),
    );
    useNewTabPlaces(setPage);
    useNewTabWeather(setPage);
    shown = page;
    return null;
  }
  const root: Root = createRoot(host);
  try {
    await act(async () => root.render(<Page />));
    expect(shown?.omnibar?.tabs ?? []).toEqual([]);

    await act(async () =>
      applyHostEvent({
        kind: "newTabPlaces",
        value: {
          tabs: [{ id: "t9", kind: "terminal", title: "zsh", detail: "~/src/relay", workspace: "workspace-9" }],
          workspaces: [{ id: "w9", name: "workspace-9" }],
        },
      }),
    );
    expect(shown?.omnibar?.tabs.map((tab) => tab.id)).toEqual(["t9"]);
    expect(shown?.omnibar?.workspaces.map((workspace) => workspace.id)).toEqual(["w9"]);
    expect(shown?.initialKind).toBe("agent");

    const reading = { place: "Berlin", temperature: 18, high: 21, low: 9, code: 2, unit: "celsius", readAt: 1_000 };
    await act(async () => applyHostEvent({ kind: "newTabWeather", value: reading }));
    expect(shown?.weather).toEqual(reading);

    // The widget turned off: null takes the reading away.
    await act(async () => applyHostEvent({ kind: "newTabWeather", value: null }));
    expect(shown?.weather).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

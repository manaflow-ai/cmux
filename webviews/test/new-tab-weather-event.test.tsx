// The New Tab weather widget's reading arrives after the page opened (the first reading of a city,
// or a refresh of an old one): the host sends it as an `acpmux-newtab-weather` event and the page
// takes it in place; a null detail (the widget turned off) takes it away.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "CustomEvent", "IS_REACT_ACT_ENVIRONMENT"] as const;
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

test("a weather event fills, replaces and clears the shown page's reading", async () => {
  const { createRoot } = await import("react-dom/client");
  const { newTabHost } = await import("../src/agent-session/acpmux/NewTabPage");
  const { NEW_TAB_WEATHER_EVENT, useNewTabWeather } = await import("../src/agent-session/acpmux/newtab/adoption");
  type Host = ReturnType<typeof newTabHost>;
  let shown: Host | undefined;
  function Page() {
    const [page, setPage] = useState<Host>(() => newTabHost({ newTab: { layout: "a", kind: "agent" } }));
    useNewTabWeather(setPage);
    shown = page;
    return null;
  }
  const reading = {
    place: "Berlin",
    temperature: 18,
    high: 21,
    low: 9,
    code: 2,
    unit: "celsius" as const,
    readAt: 1_000,
  };
  const send = (detail: unknown) =>
    act(() => {
      window.dispatchEvent(new window.CustomEvent(NEW_TAB_WEATHER_EVENT, { detail }));
    });
  const root: Root = createRoot(host);
  await act(async () => root.render(<Page />));
  expect(shown?.weather).toBeUndefined();

  await send(reading);
  expect(shown?.weather).toEqual(reading);
  expect(shown?.initialKind).toBe("agent");

  await send({ ...reading, temperature: 20, readAt: 2_000 });
  expect(shown?.weather?.temperature).toBe(20);

  await send(null);
  expect(shown?.weather).toBeUndefined();
  await act(async () => root.unmount());
});

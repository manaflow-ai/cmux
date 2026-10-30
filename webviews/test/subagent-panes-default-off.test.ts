// A chat pane opened a split for every subagent its chat started unless the user had turned that
// off in the summary card, and agent panes keep their storage only until the app quits, so the
// splits came back after each restart. New subagents now open panes only once the user turns the
// switch on, and a click shows the subagent in the chat until then (subagents/subagentPanes.ts).
// The switch is `agentPane.subagentPanes` in cmux.json: the host pushes it with the composer's
// settings, and the switch asks the host to write it (composerSettings.ts).
import { afterEach, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import {
  DEFAULT_COMPOSER,
  registerComposerHost,
  setComposerSettings,
} from "../src/agent-session/acpmux/composerSettings";
import { adoptStoredSubagentPanes, useAutoOpenSubagents } from "../src/agent-session/acpmux/subagents/subagentPanes";

const KEY = "cmux.acpmux.subagentPanes";
const original = Object.getOwnPropertyDescriptor(globalThis, "localStorage");

const withStorage = (items: Record<string, string>) => {
  const store = new Map(Object.entries(items));
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => void store.set(key, value),
      removeItem: (key: string) => void store.delete(key),
    },
  });
  return store;
};

/// The host's writes, as `method=value`.
const withHost = () => {
  const writes: string[] = [];
  registerComposerHost((method, show) => writes.push(`${method}=${show}`));
  return writes;
};

afterEach(() => {
  if (original) Object.defineProperty(globalThis, "localStorage", original);
  else delete (globalThis as { localStorage?: unknown }).localStorage;
  registerComposerHost(undefined);
  setComposerSettings(DEFAULT_COMPOSER);
});

let setSwitch: ((on: boolean) => void) | undefined;
const Probe = () => {
  const [on, set] = useAutoOpenSubagents();
  setSwitch = set;
  return createElement("span", null, on ? "on" : "off");
};
const render = () => renderToStaticMarkup(createElement(Probe));

test("new subagents open no panes until the user turns it on", () => {
  withStorage({});
  expect(render()).toBe("<span>off</span>");
});

test("agentPane.subagentPanes on in cmux.json opens panes for new subagents", () => {
  setComposerSettings({ ...DEFAULT_COMPOSER, subagentPanes: true });
  expect(render()).toBe("<span>on</span>");
});

test("the switch asks the host to write agentPane.subagentPanes", () => {
  const writes = withHost();
  render();
  setSwitch?.(true);
  expect(render()).toBe("<span>on</span>");
  setSwitch?.(false);
  expect(writes).toEqual(["pane.subagentPanes=true", "pane.subagentPanes=false"]);
});

test("a switch turned on in the page's storage moves into the setting once", () => {
  const store = withStorage({ [KEY]: "on" });
  const writes = withHost();
  adoptStoredSubagentPanes();
  expect(render()).toBe("<span>on</span>");
  expect(writes).toEqual(["pane.subagentPanes=true"]);
  expect(store.has(KEY)).toBe(false);
  adoptStoredSubagentPanes();
  expect(writes).toEqual(["pane.subagentPanes=true"]);
});

test("storage that never turned the switch on writes nothing", () => {
  withStorage({ [KEY]: "off" });
  const writes = withHost();
  adoptStoredSubagentPanes();
  expect(render()).toBe("<span>off</span>");
  expect(writes).toEqual([]);
});

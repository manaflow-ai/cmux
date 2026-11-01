// A chat pane opened a split for every subagent its chat started unless the user had turned that
// off in the summary card, and agent panes keep their storage only until the app quits, so the
// splits came back after each restart. New subagents now open panes only once the user turns the
// switch on, and a click shows the subagent in the chat until then (subagents/subagentPanes.ts).
import { afterEach, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { useAutoOpenSubagents } from "../src/agent-session/acpmux/subagents/subagentPanes";

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
};

afterEach(() => {
  if (original) Object.defineProperty(globalThis, "localStorage", original);
  else delete (globalThis as { localStorage?: unknown }).localStorage;
});

const Probe = () => {
  const [on] = useAutoOpenSubagents();
  return createElement("span", null, on ? "on" : "off");
};
const render = () => renderToStaticMarkup(createElement(Probe));

test("new subagents open no panes until the user turns it on", () => {
  withStorage({});
  expect(render()).toBe("<span>off</span>");
});

test("the switch turned on opens panes for new subagents", () => {
  withStorage({ [KEY]: "on" });
  expect(render()).toBe("<span>on</span>");
});

test("a pane the user turned off stays off", () => {
  withStorage({ [KEY]: "off" });
  expect(render()).toBe("<span>off</span>");
});

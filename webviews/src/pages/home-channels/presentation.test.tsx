// Home Channels' header control is the same four-level ladder as the agent chat's menu
// (agent-session/acpmux/chatDetail.ts). The old Messages | Transcript choice still reads.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import { DetailToggle, readDetail, resetDetails, setDetail } from "./presentation";

const scope = globalThis as Record<string, unknown>;
let dom: JSDOM;
const saved = new Map<string, unknown>();

beforeAll(() => {
  dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  for (const key of ["window", "localStorage"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, localStorage: dom.window.localStorage });
});

afterAll(() => {
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

afterEach(() => {
  resetDetails();
  localStorage.clear();
});

const strings = { language: "en", t: (key: string) => key, format: (key: string) => key } as Strings;

test("a conversation starts at Messages", () => {
  expect(readDetail("c")).toBe("messages");
  expect(readDetail(undefined)).toBe("messages");
});

test("the old Transcript choice reads as Normal", () => {
  localStorage.setItem("cmux.home.presentation:c", "transcript");
  expect(readDetail("c")).toBe("normal");
});

test("a pick is this conversation's only, and wins over the old choice", () => {
  localStorage.setItem("cmux.home.presentation:c", "transcript");
  setDetail("c", "verbose");
  expect(readDetail("c")).toBe("verbose");
  expect(readDetail("d")).toBe("messages");
  setDetail("c", "messages");
  expect(readDetail("c")).toBe("messages");
});

test("the header shows the four levels in order", () => {
  setDetail("c", "thinking");
  const markup = renderToStaticMarkup(<DetailToggle conversation="c" strings={strings} />);
  const labels = [...markup.matchAll(/<button[^>]*aria-pressed="(true|false)"[^>]*>([^<]+)</g)].map((m) => [
    m[2],
    m[1],
  ]);
  expect(labels).toEqual([
    ["detail.messages", "false"],
    ["detail.normal", "false"],
    ["detail.thinking", "true"],
    ["detail.verbose", "false"],
  ]);
});

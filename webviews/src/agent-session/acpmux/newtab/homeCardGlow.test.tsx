import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { settleReact } from "../../../../test/support/domTeardown";
import { ChatCards } from "./ChatCards";
import { experimentArm } from "../../../experiments/experiment";
import { homeCardGlow, homeCardTint } from "./homeCardGlow.experiment";
import type { ChatCard } from "./screenModel";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "localStorage",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.getElementById("root") as HTMLElement;
  root = createRoot(container);
});

afterEach(async () => {
  act(() => root?.unmount());
  await settleReact();
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const cards: ChatCard[] = [
  { sessionId: "s-1", title: "One", age: "2m", state: "idle", message: "Done." },
  { sessionId: "s-2", chatId: "chat-2", title: "Two", age: "1h", state: "running" },
];

const render = (props: Partial<Parameters<typeof ChatCards>[0]> = {}) =>
  act(() => root!.render(<ChatCards cards={cards} onOpen={() => undefined} {...props} />));

test("the experiment ships off", () => {
  expect(homeCardGlow.defaultArm).toBe("off");
  expect(experimentArm(homeCardGlow, { overrides: {}, stored: {} })).toBe("off");
});

test("off draws the cards exactly as before: no glow attribute and no tint", async () => {
  await render();
  expect(container.querySelector(".nt-cards")!.hasAttribute("data-glow")).toBe(false);
  for (const card of container.querySelectorAll<HTMLElement>(".nt-card")) expect(card.getAttribute("style")).toBeNull();
});

test("a glow arm tints each card with its chat's own color and keeps the card's contents", async () => {
  await render({ glow: "subtle" });
  const plain = container.querySelectorAll(".nt-card");
  expect(container.querySelector(".nt-cards")!.getAttribute("data-glow")).toBe("subtle");
  const shown = [...container.querySelectorAll<HTMLElement>(".nt-card")];
  expect(shown.length).toBe(plain.length);
  expect(shown[0]!.style.getPropertyValue("--nt-card-tint")).toBe(homeCardTint(cards[0]!));
  expect(shown[1]!.style.getPropertyValue("--nt-card-tint")).toBe(homeCardTint(cards[1]!));
  expect(shown[0]!.querySelector(".nt-card-title")!.textContent).toBe("One");
});

test("the list layout never glows", async () => {
  await render({ glow: "vivid", variant: "list" });
  expect(container.querySelector(".nt-cards")!.hasAttribute("data-glow")).toBe(false);
});

test("a chat's tint is stable and follows its harness chat id", () => {
  expect(homeCardTint({ sessionId: "a" })).toBe(homeCardTint({ sessionId: "a" }));
  expect(homeCardTint({ sessionId: "x", chatId: "same" })).toBe(homeCardTint({ sessionId: "y", chatId: "same" }));
});

test("the hover brightening is gated on reduced motion and moves only opacity", () => {
  const css = readFileSync(new URL("./screen.css", import.meta.url), "utf8");
  const start = css.indexOf("/* The home-card-glow experiment");
  expect(start).toBeGreaterThan(-1);
  const block = css.slice(start);
  const gate = block.indexOf("@media (prefers-reduced-motion: no-preference)");
  expect(gate).toBeGreaterThan(-1);
  expect(block.slice(0, gate)).not.toContain("transition");
  expect(block.slice(gate)).toMatch(/transition:\s*opacity var\(--cmux-motion-/);
});

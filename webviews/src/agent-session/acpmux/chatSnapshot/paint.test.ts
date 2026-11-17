// A copy drawn under another theme takes the live root's look: its own theme's look attributes that the
// live theme leaves out go, so an old working look or decoration draws nothing before the swap (review F2
// at cmux#43281: "same-appearance copies can retain stale root look attributes").
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { isHostLookAttribute, layerHostTheme } from "./paint";

function elements(standAttributes: Record<string, string>, rootAttributes: Record<string, string>) {
  const doc = new JSDOM("<!doctype html><html><body></body></html>").window.document;
  const stand = doc.createElement("div");
  for (const [name, value] of Object.entries(standAttributes)) stand.setAttribute(name, value);
  const root = doc.documentElement;
  for (const [name, value] of Object.entries(rootAttributes)) root.setAttribute(name, value);
  return { stand, root };
}

test("a look attribute only the copy's theme set is removed, and the live ones are layered", () => {
  const { stand, root } = elements(
    { "data-working-look": "pulse", "data-cmux-decoration-border": "neon", "data-glass": "on" },
    { "data-glass": "off", "data-cmux-motion": "reduced" },
  );
  layerHostTheme(stand, root);
  expect(stand.hasAttribute("data-working-look")).toBe(false);
  expect(stand.hasAttribute("data-cmux-decoration-border")).toBe(false);
  expect(stand.getAttribute("data-glass")).toBe("off");
  expect(stand.getAttribute("data-cmux-motion")).toBe("reduced");
});

test("the copy's page-state attributes stay: the host never sets them", () => {
  const { stand, root } = elements({ "data-composer-open": "true", "data-scrollers": "overlay" }, {});
  layerHostTheme(stand, root);
  expect(stand.getAttribute("data-composer-open")).toBe("true");
  expect(stand.hasAttribute("data-scrollers")).toBe(false);
});

test("the host's look attributes are its fixed names and every decoration slot", () => {
  for (const name of [
    "data-scrollers",
    "data-status-indicators",
    "data-working-look",
    "data-cmux-motion",
    "data-glass",
    "data-cmux-font-smoothing",
    "data-cmux-decoration-anything",
  ])
    expect(isHostLookAttribute(name)).toBe(true);
  expect(isHostLookAttribute("data-composer-open")).toBe(false);
});

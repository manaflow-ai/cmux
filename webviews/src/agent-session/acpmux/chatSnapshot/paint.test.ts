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

test("the copy takes the live theme's agent colors the host served, and drops the ones it leaves out", () => {
  // Review at f951e21: "a same-appearance copy can briefly show the previous launch's agent colors".
  const { stand, root } = elements({}, {});
  stand.style.setProperty("--agent-accent", "rgba(255, 0, 0, 1)");
  stand.style.setProperty("--agent-danger", "rgba(9, 9, 9, 1)");
  stand.style.setProperty("--agent-ansi-3", "rgba(1, 1, 1, 1)");
  layerHostTheme(stand, root, {
    accent: "rgba(0, 0, 255, 1)",
    text: "rgba(10, 20, 30, 1)",
    palette: ["rgba(0, 0, 0, 1)"],
  });
  expect(stand.style.getPropertyValue("--agent-accent")).toBe("rgba(0, 0, 255, 1)");
  expect(stand.style.getPropertyValue("--agent-text")).toBe("rgba(10, 20, 30, 1)");
  expect(stand.style.getPropertyValue("--agent-ansi-0")).toBe("rgba(0, 0, 0, 1)");
  // A color the live theme leaves out keeps nothing of the old theme's, as the page's theme apply clears it.
  expect(stand.style.getPropertyValue("--agent-danger")).toBe("");
  expect(stand.style.getPropertyValue("--agent-ansi-3")).toBe("");
});

test("with no agent theme served, the copy keeps its own colors", () => {
  const { stand, root } = elements({}, {});
  stand.style.setProperty("--agent-accent", "rgba(255, 0, 0, 1)");
  layerHostTheme(stand, root, null);
  expect(stand.style.getPropertyValue("--agent-accent")).toBe("rgba(255, 0, 0, 1)");
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

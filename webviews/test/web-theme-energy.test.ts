// Energy Saver reaches every cmux page through the one web theme: the app's
// WebTheme bootstrap sets `data-cmux-energy="saver"` on <html> when the payload carries
// `energy: "saver"` and removes it when the payload has none, next to `data-cmux-motion`.
// The stylesheets hold their ambient loops still under it.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { readWebThemeBootstrap } from "../dev-server/galleryHost";

const bootstrap = readWebThemeBootstrap();

function page() {
  const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { runScripts: "outside-only" });
  dom.window.eval(bootstrap);
  const apply = (payload: Record<string, unknown>) =>
    dom.window.eval(`window.cmuxTheme.apply(${JSON.stringify({ variables: {}, colorScheme: "dark", ...payload })})`);
  return { root: dom.window.document.documentElement, apply };
}

test("saver on sets the attribute, saver off removes it", () => {
  const { root, apply } = page();
  apply({ motion: "full" });
  expect(root.hasAttribute("data-cmux-energy")).toBe(false);
  apply({ motion: "full", energy: "saver" });
  expect(root.getAttribute("data-cmux-energy")).toBe("saver");
  apply({ motion: "full" });
  expect(root.hasAttribute("data-cmux-energy")).toBe(false);
});

test("the saver leaves the motion mark alone", () => {
  const { root, apply } = page();
  apply({ motion: "full", energy: "saver" });
  expect(root.getAttribute("data-cmux-motion")).toBe("full");
  apply({ motion: "off", energy: "saver" });
  expect(root.getAttribute("data-cmux-motion")).toBe("off");
  expect(root.getAttribute("data-cmux-energy")).toBe("saver");
});

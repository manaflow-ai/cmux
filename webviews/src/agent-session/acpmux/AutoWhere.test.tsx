import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { AutoAddingMachineLine, AutoIcon } from "./AutoWhere";
import { autoAddingMachineLine } from "./autoWhereModel";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete (globalThis as Record<string, unknown>)[key];
    else (globalThis as Record<string, unknown>)[key] = value;
  }
  saved.clear();
});

test("the scale-up line renders in Auto styling and clears with the warning", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  const container = dom.window.document.getElementById("root")!;
  const globals = {
    window: dom.window,
    document: dom.window.document,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
    __cmuxPaneStrings: { en: { "auto.addingMachine": "Auto is adding a machine" } },
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, (globalThis as Record<string, unknown>)[key]);
    (globalThis as Record<string, unknown>)[key] = value;
  }
  root = createRoot(container);
  const text = autoAddingMachineLine({ scalingUp: true });
  expect(text).toBe("auto.addingMachine");
  await act(async () => root!.render(text ? <AutoAddingMachineLine text={text} look="orbit" /> : null));
  expect(container.querySelector(".acpmux-auto-arrival")?.textContent).toContain("Auto is adding a machine");
  expect(container.querySelector('[data-auto-look="orbit"]')).not.toBeNull();
  const cleared = autoAddingMachineLine({ scalingUp: false });
  expect(cleared).toBeUndefined();
  await act(async () => root!.render(cleared ? <AutoAddingMachineLine text={cleared} look="orbit" /> : null));
  expect(container.querySelector(".acpmux-auto-arrival")).toBeNull();
});

// cmux#51731: Auto's icon reads as this Mac and Cloud at once, a laptop with a cloud badge, in the
// other rows' 14px box (DevicesIcon, EnvironmentIcon) and stroke.
test("Auto's shipped icon is a laptop with a cloud badge, the other icons' size", () => {
  const html = renderToStaticMarkup(<AutoIcon look="split" />);
  expect(html).toContain('data-look="split"');
  expect(html).toContain('width="14"');
  expect(html).toContain('height="14"');
  expect(html).toContain('viewBox="0 0 16 16"');
  expect(html).toContain('stroke-width="1.25"');
  // The laptop: a screen and its base, cut where the badge sits.
  expect(html).toMatch(/<g mask="url\(#[^)]+\)"><rect [^>]*width="10.5"/);
  expect(html).toContain('d="M.75 13.25h13"');
  // The badge: a filled cloud in Cloud's colour, and no slash between two halves.
  expect(html).toMatch(/class="acpmux-auto-split-cloud"[^>]*fill="var\(--agent-ansi-4, currentColor\)"/);
  expect(html).not.toContain("acpmux-auto-split-slash");
});

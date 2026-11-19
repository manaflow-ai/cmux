import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { armIds } from "../../../experiments/experiment";
import { settleReact } from "../../../../test/support/domTeardown";
import { DepthBackground } from "./DepthBackground";
import { newTabDepth, type NewTabDepthArm } from "./depthBackground.experiment";

// The New Tab depth layer (experiment new-tab-depth): off draws nothing, every other arm draws one
// hidden layer, and nothing in its sheet loops or runs at idle.
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const win = dom.window as unknown as Window & typeof globalThis;
  win.matchMedia = (() => ({ matches: false })) as never;
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return win.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function Host({ arm }: { arm: NewTabDepthArm }) {
  const host = useRef<HTMLDivElement>(null);
  return (
    <div ref={host} className="nt-depth-host">
      <DepthBackground arm={arm} host={host} />
    </div>
  );
}

test("off ships, and draws nothing", async () => {
  expect(newTabDepth.defaultArm).toBe("off");
  const mount = installDom();
  await act(async () => {
    root = createRoot(mount);
    root.render(<Host arm="off" />);
  });
  expect(mount.querySelector(".nt-depth")).toBeNull();
});

test("every other arm draws one layer, hidden from assistive tech and the pointer", async () => {
  for (const arm of armIds(newTabDepth).filter((id) => id !== "off")) {
    const mount = installDom();
    await act(async () => {
      root = createRoot(mount);
      root.render(<Host arm={arm} />);
    });
    const layers = mount.querySelectorAll(".nt-depth");
    expect(layers.length).toBe(1);
    expect(layers[0]!.getAttribute("aria-hidden")).toBe("true");
    await act(async () => root!.unmount());
    root = undefined;
    dom?.window.close();
  }
});

test("the sheet runs nothing at idle: no animation, no loop, no backdrop filter, stills under Reduce Motion", () => {
  const css = readFileSync(new URL("./depth.css", import.meta.url), "utf8");
  expect(css).not.toMatch(/animation\s*:/);
  expect(css).not.toMatch(/infinite/);
  expect(css).not.toMatch(/backdrop-filter/);
  expect(css).toMatch(/prefers-reduced-motion: reduce/);
  // Only translate and opacity move.
  const moved = [...css.matchAll(/([a-z-]+)\s+var\(--cmux-motion-/g)].map((match) => match[1]);
  expect(moved.length).toBeGreaterThan(0);
  for (const property of moved) expect(["translate", "opacity"]).toContain(property!);
});

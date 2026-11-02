// A project's badge in the pickers (the New Tab strip, the composer's folder menu) shows the
// project's own icon when the host finds one (`project.icon`, read on this Mac only), else its
// framework's mark, and a plain folder otherwise: no icon, a refusal, or a remote project, which the
// page never asks about.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ProjectBadge } from "./ProjectBadge";
import { GLYPHS } from "./projectGlyphs";
import { setProjectIconHost } from "./projectIcon";

const ICON = "data:image/png;base64,iVBORw0KGgo=";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  setProjectIconHost(undefined);
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(project: Parameters<typeof ProjectBadge>[0]["project"]): Promise<HTMLElement> {
  const container = installDom();
  root = createRoot(container);
  await act(async () => {
    root!.render(<ProjectBadge project={project} />);
  });
  // The host's answer lands in a task after the first paint.
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  return container.querySelector<HTMLElement>(".acpmux-project-badge")!;
}

test("a local project with a favicon shows it in its badge", async () => {
  const asked: unknown[] = [];
  setProjectIconHost(async (method, params) => {
    asked.push([method, params]);
    return { src: ICON };
  });
  const badge = await render({ cwd: "/Users/me/code/site", label: "site" });
  expect(asked).toEqual([["project.icon", { cwd: "/Users/me/code/site" }]]);
  const image = badge.querySelector("img");
  expect(image?.getAttribute("src")).toBe(ICON);
  expect(badge.textContent).toBe("");
});

// The avatar comes first, so an avatar WebKit cannot draw is how a GitHub project shows its mark.
test("an icon that fails to draw falls back to the framework's mark", async () => {
  setProjectIconHost(async () => ({ src: ICON, glyph: "rust" }));
  const badge = await render({ cwd: "/Users/me/code/engine", label: "engine" });
  expect(badge.dataset.projectGlyph).toBeUndefined();
  await act(async () => {
    badge.querySelector("img")!.dispatchEvent(new dom!.window.Event("error"));
  });
  expect(badge.querySelector("img")).toBeNull();
  expect(badge.dataset.projectGlyph).toBe("rust");
  expect(badge.querySelector("svg path")?.getAttribute("d")).toBe(GLYPHS.rust.path);
});

// Leo 2026-10-21 on the New Tab project picker: two-letter tiles (PR, CM, CG, LW) with a grey dot.
test("a project with no icon and no language draws a folder, never its letters", async () => {
  setProjectIconHost(async () => ({}));
  const badge = await render({ cwd: "/Users/me/code/cmux-next", label: "cmux next" });
  expect(badge.querySelector("img")).toBeNull();
  expect(badge.hasAttribute("data-project-folder")).toBe(true);
  expect(badge.querySelector("svg path")).not.toBeNull();
  expect(badge.textContent).toBe("");
});

test("a project with no image shows its framework's mark in the brand color", async () => {
  setProjectIconHost(async () => ({ glyph: "vite" }));
  const badge = await render({ cwd: "/Users/me/code/app", label: "app" });
  expect(badge.dataset.projectGlyph).toBe("vite");
  expect(badge.querySelector("svg path")?.getAttribute("d")).toBe(GLYPHS.vite.path);
  expect(badge.style.getPropertyValue("--acpmux-project-badge")).toBe(GLYPHS.vite.color);
});

test("a glyph the page does not know draws the folder", async () => {
  setProjectIconHost(async () => ({ glyph: "cobol" }));
  const badge = await render({ cwd: "/Users/me/code/mainframe", label: "mainframe" });
  expect(badge.dataset.projectGlyph).toBeUndefined();
  expect(badge.hasAttribute("data-project-folder")).toBe(true);
});

test("an empty first answer does not cache the generic folder over a later project icon", async () => {
  let calls = 0;
  setProjectIconHost(async () => {
    calls += 1;
    return calls === 1 ? {} : { src: ICON };
  });
  const first = await render({ cwd: "/Users/me/code/recover", label: "recover" });
  expect(first.querySelector("img")).toBeNull();
  act(() => root?.unmount());
  root = createRoot(document.getElementById("root")!);
  await act(async () => {
    root!.render(<ProjectBadge project={{ cwd: "/Users/me/code/recover", label: "recover" }} />);
  });
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(document.querySelector(".acpmux-project-badge img")?.getAttribute("src")).toBe(ICON);
});

test("an answer that is not an image data URL draws the folder", async () => {
  setProjectIconHost(async () => ({ src: "https://example.com/favicon.ico" }));
  const badge = await render({ cwd: "/Users/me/code/elsewhere", label: "elsewhere" });
  expect(badge.querySelector("img")).toBeNull();
  expect(badge.hasAttribute("data-project-folder")).toBe(true);
  expect(badge.textContent).toBe("");
});

test("no badge draws a corner dot, whatever its kind", async () => {
  const { readFileSync } = await import("node:fs");
  const css = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
  expect(css).not.toMatch(/\.acpmux-project-badge[^{,]*::(?:after|before)\s*\{/);
});

test("a remote project never asks this Mac for an icon", async () => {
  const asked: unknown[] = [];
  setProjectIconHost(async (method) => {
    asked.push(method);
    return { src: ICON };
  });
  const badge = await render({ cwd: "/home/me/api", label: "api", peer: "devbox" });
  expect(asked).toEqual([]);
  expect(badge.querySelector("img")).toBeNull();
  expect(badge.textContent).toBe("");
});

test("a badge that moves to another project drops the old icon before the host answers", async () => {
  let answer: (value: unknown) => void = () => undefined;
  setProjectIconHost(async (_method, params) =>
    params.cwd === "/Users/me/code/site" ? { src: ICON } : new Promise((resolve) => (answer = resolve)),
  );
  const badge = await render({ cwd: "/Users/me/code/site", label: "site" });
  expect(badge.querySelector("img")).not.toBeNull();
  await act(async () => {
    root!.render(<ProjectBadge project={{ cwd: "/Users/me/code/other", label: "other" }} />);
  });
  const moved = document.querySelector<HTMLElement>(".acpmux-project-badge")!;
  expect(moved.querySelector("img")).toBeNull();
  expect(moved.hasAttribute("data-project-folder")).toBe(true);
  await act(async () => answer({}));
});

test("a failed ask is asked again by the next badge", async () => {
  let calls = 0;
  setProjectIconHost(async () => {
    calls += 1;
    if (calls === 1) throw new Error("page not connected yet");
    return { src: ICON };
  });
  const first = await render({ cwd: "/Users/me/code/retry", label: "retry" });
  expect(first.querySelector("img")).toBeNull();
  act(() => root?.unmount());
  root = createRoot(document.getElementById("root")!);
  await act(async () => {
    root!.render(<ProjectBadge project={{ cwd: "/Users/me/code/retry", label: "retry" }} />);
  });
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(document.querySelector(".acpmux-project-badge img")?.getAttribute("src")).toBe(ICON);
});

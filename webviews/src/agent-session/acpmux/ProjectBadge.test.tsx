// A project's badge in the pickers (the New Tab strip, the composer's folder menu) shows the
// project's own favicon when the host finds one (`project.icon`, read on this Mac only), and its
// letters otherwise: no icon, a refusal, or a remote project, which the page never asks about.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ProjectBadge } from "./ProjectBadge";
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

test("a project with no favicon keeps its letters", async () => {
  setProjectIconHost(async () => ({}));
  const badge = await render({ cwd: "/Users/me/code/cmux-next", label: "cmux next" });
  expect(badge.querySelector("img")).toBeNull();
  expect(badge.textContent).toBe("CN");
});

test("an answer that is not an image data URL keeps the letters", async () => {
  setProjectIconHost(async () => ({ src: "https://example.com/favicon.ico" }));
  const badge = await render({ cwd: "/Users/me/code/elsewhere", label: "elsewhere" });
  expect(badge.querySelector("img")).toBeNull();
  expect(badge.textContent).toBe("EL");
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
  expect(badge.textContent).toBe("AP");
});

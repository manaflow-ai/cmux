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
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "customElements",
    "HTMLTemplateElement",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    // The file-type icon set (@pierre/trees) registers its tree element when it loads.
    customElements: dom.window.customElements,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
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
  expect(moved.textContent).toBe("OT");
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

/// The lazily loaded icon module lands, then React draws it.
async function settleIcons() {
  await act(async () => {
    await import("./changes/FileTypeIcon");
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

test("a project with no favicon shows its language's icon from its marker files", async () => {
  setProjectIconHost(async () => ({ language: "swift" }));
  const badge = await render({ cwd: "/Users/me/code/kit", label: "kit" });
  await settleIcons();
  expect(badge.dataset.projectLanguage).toBe("swift");
  expect(badge.querySelector("svg[data-icon='swift']")).not.toBeNull();
  expect(badge.textContent).toBe("");
  // In its type's color: Swift's hue on a badge that colors its icon (fileIcons.experiment.ts).
  expect(badge.dataset.iconColor).toBe("theme");
  expect(badge.querySelector("svg")?.getAttribute("data-icon-hue")).toBe("orange");
});

test("a favicon wins over the language, and a language cmux has no icon for keeps the letters", async () => {
  setProjectIconHost(async (_method, params) =>
    params.cwd === "/Users/me/code/site" ? { src: ICON, language: "nextjs" } : { language: "cobol" },
  );
  const site = await render({ cwd: "/Users/me/code/site", label: "site" });
  expect(site.querySelector("img")?.getAttribute("src")).toBe(ICON);
  act(() => root?.unmount());
  root = undefined;
  const legacy = await render({ cwd: "/Users/me/code/ledger", label: "ledger" });
  expect(legacy.querySelector("svg")).toBeNull();
  expect(legacy.textContent).toBe("LE");
});

test("with the language icons experiment off, a project without a favicon keeps its letters", async () => {
  setProjectIconHost(async () => ({ language: "rust" }));
  globalThis.cmuxExperiments = { "project-language-icons": "off" };
  try {
    const badge = await render({ cwd: "/Users/me/code/tui", label: "tui" });
    await settleIcons();
    expect(badge.querySelector("svg")).toBeNull();
    expect(badge.textContent).toBe("TU");
  } finally {
    globalThis.cmuxExperiments = undefined;
  }
});

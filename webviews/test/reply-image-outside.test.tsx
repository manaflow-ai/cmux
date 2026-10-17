import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

/// A reply image outside the chat's folders (a screenshot in a temporary folder) follows
/// `agentPane.links.outsideRoots`: Open shows it at once, Ask First after Load image, Text never.
async function render(outsideRoots: "open" | "confirm" | "text") {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { ReplyImage } = await import("../src/agent-session/acpmux/chips/ReplyImage");
  const { seedLinkStore, resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const path = `/tmp/shot-${outsideRoots}.png`;
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  const calls: string[] = [];
  resetLinkStore();
  seedLinkStore({ paths: { [path]: { place: "outside", folder: false } }, policy: { outsideRoots } });
  setChipHost(async (method, params) => {
    calls.push(`${method} ${String(params.src ?? params.path)}`);
    return method === "image.load" ? { src: PNG } : undefined;
  });
  await act(async () => {
    root.render(<ReplyImage src={path} alt="" fallback={<span className="fallback">{path}</span>} />);
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const done = async () => {
    await act(async () => root.unmount());
    setChipHost(undefined);
  };
  return { act, rootElement, calls, path, done };
}

test("an outside image shows at once when outside files open", async () => {
  const { rootElement, calls, path, done } = await render("open");
  expect(calls).toEqual([`image.load ${path}`]);
  expect(rootElement.querySelector("img.cv-img")?.getAttribute("src")).toBe(PNG);
  await done();
});

test("an outside image waits for Load image when outside files ask first", async () => {
  const { act, rootElement, calls, path, done } = await render("confirm");
  expect(calls).toEqual([]);
  expect(rootElement.querySelector("img")).toBeNull();
  const button = rootElement.querySelector<HTMLButtonElement>(".cv-image-file__open")!;
  expect(button.textContent).toBe("Load image");
  await act(async () => {
    button.click();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(calls).toEqual([`image.load ${path}`]);
  expect(rootElement.querySelector("img.cv-img")?.getAttribute("src")).toBe(PNG);
  await done();
});

test("an outside image stays a name when outside files show as text", async () => {
  const { rootElement, calls, done } = await render("text");
  expect(calls).toEqual([]);
  expect(rootElement.querySelector("img")).toBeNull();
  expect(rootElement.querySelector(".cv-image-file .cv-chip__lock")).not.toBeNull();
  expect(rootElement.querySelector("button")).toBeNull();
  await done();
});

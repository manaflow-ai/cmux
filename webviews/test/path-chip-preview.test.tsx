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

type Call = { method: string; params: Record<string, unknown> };

async function renderChip(
  path: string,
  seed: Parameters<typeof import("../src/agent-session/acpmux/chips/linkStore").seedLinkStore>[0],
  answer: (call: Call) => unknown,
) {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { PathChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const { seedLinkStore, resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  const calls: Call[] = [];
  resetLinkStore();
  seedLinkStore(seed);
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    return answer({ method, params });
  });
  await act(async () => {
    root.render(
      <UiProvider container={rootElement}>
        <p>
          Saved <PathChip path={path} written={path} />
        </p>
      </UiProvider>,
    );
  });
  const chip = rootElement.querySelector<HTMLButtonElement>("button.cv-chip.is-path")!;
  return {
    act,
    calls,
    chip,
    rootElement,
    card: () => rootElement.querySelector<HTMLElement>(".cv-path-preview"),
    done: async () => {
      await act(async () => root.unmount());
      setChipHost(undefined);
    },
  };
}

const PNG = "data:image/png;base64,iVBORw0KGgo=";

test("a locked chip outside the session's folders previews on hover and its click asks the host to open it", async () => {
  const path = "/tmp/cmux-shots/after-opened.png";
  const view = await renderChip(
    path,
    { paths: { [path]: { place: "outside", folder: false } }, policy: { outsideRoots: "confirm" } },
    ({ method }) => (method === "image.load" ? { src: PNG } : undefined),
  );
  const before = dom.window.location.href;
  // The lock is drawn, and the chip is still a button that opens.
  expect(view.chip.classList.contains("is-outside")).toBe(true);
  expect(view.chip.querySelector(".cv-chip__lock")).not.toBeNull();
  await view.act(async () => view.chip.focus());
  await view.act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const card = view.card()!;
  expect(card).not.toBeNull();
  expect(card.getAttribute("aria-label")).toBe("after-opened.png");
  expect(card.textContent).toContain(path);
  expect(card.querySelector<HTMLImageElement>("img.cv-path-preview__image")?.getAttribute("src")).toBe(PNG);
  expect(view.calls).toContainEqual({ method: "image.load", params: { src: path } });

  await view.act(async () => view.chip.click());
  // The open goes to the host (`link.openPath`), which places it by "Open new tabs and links"
  // (on the right by default): the chat pane itself never navigates.
  expect(view.calls.at(-1)).toEqual({ method: "link.openPath", params: { path } });
  expect(view.calls.some((call) => call.method === "browser.open" || call.method === "browser.openIn")).toBe(false);
  expect(dom.window.location.href).toBe(before);

  // The card's own Open is the same request.
  await view.act(async () => card.querySelector<HTMLButtonElement>(".cv-link-preview__open")!.click());
  expect(view.calls.at(-1)).toEqual({ method: "link.openPath", params: { path } });
  await view.done();
});

test("a text file's hover card shows its first lines from the host's bounded read", async () => {
  const path = "/Users/you/src/atlas-web/logs/build.log";
  const view = await renderChip(path, { paths: { [path]: { place: "root", folder: false } } }, ({ method }) =>
    method === "link.preview" ? { lines: ["$ bun run build", "built in 2.1s"], truncated: true } : undefined,
  );
  await view.act(async () => view.chip.focus());
  await view.act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const text = view.card()!.querySelector<HTMLElement>("pre.cv-path-preview__text")!;
  expect(text.textContent).toBe("$ bun run build\nbuilt in 2.1s");
  expect(text.dataset.truncated).toBe("true");
  expect(view.calls).toEqual([{ method: "link.preview", params: { path } }]);
  await view.done();
});

test("a folder's card has its name and Open but reads nothing", async () => {
  const path = "/Users/you/src/atlas-web/src/";
  const view = await renderChip(path, { paths: { [path]: { place: "root", folder: true } } }, () => undefined);
  await view.act(async () => view.chip.focus());
  expect(view.card()?.textContent).toContain("src");
  expect(view.card()?.querySelector("pre, img")).toBeNull();
  expect(view.calls).toEqual([]);
  await view.done();
});

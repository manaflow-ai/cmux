import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const globals: Record<string, unknown> = {
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
};
const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => Object.assign(scope, globals));
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

type Call = { method: string; params: Record<string, unknown> };

/// The last test's teardown: a failed test never reaches its `done()`, and its chip must not stay
/// on the page for the next one.
let leftover: (() => Promise<void>) | undefined;

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
  await leftover?.();
  const rootElement = dom.window.document.createElement("div");
  dom.window.document.body.append(rootElement);
  const root = createRoot(rootElement);
  const calls: Call[] = [];
  let unmounted = false;
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
  const teardown = async () => {
    if (!unmounted) await act(async () => root.unmount());
    unmounted = true;
    rootElement.remove();
    setChipHost(undefined);
    leftover = undefined;
  };
  leftover = teardown;
  const chip = rootElement.querySelector<HTMLButtonElement>("button.cv-chip.is-path")!;
  return {
    act,
    calls,
    chip,
    rootElement,
    card: () => rootElement.querySelector<HTMLElement>(".cv-path-preview"),
    /// Lets the host's answer arrive: a deadline-bounded poll, never a fixed sleep.
    until: async (ready: () => unknown) => {
      const deadline = Date.now() + 2000;
      while (!ready() && Date.now() < deadline) {
        await act(async () => {
          await new Promise((resolve) => setTimeout(resolve, 0));
        });
      }
    },
    unmount: () => {
      if (!unmounted) root.unmount();
      unmounted = true;
    },
    done: teardown,
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
  await view.until(() => view.card()?.querySelector("img, pre"));
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
  await view.until(() => view.card()?.querySelector("img, pre"));
  const text = view.card()!.querySelector<HTMLElement>("pre.cv-path-preview__text")!;
  expect(text.textContent).toBe("$ bun run build\nbuilt in 2.1s");
  expect(text.dataset.truncated).toBe("true");
  expect(view.calls).toEqual([{ method: "link.preview", params: { path } }]);
  await view.done();
});

test("a folder's card has its name and Open, and only asks whether the chat is on this Mac", async () => {
  const path = "/Users/you/src/atlas-web/src/";
  const view = await renderChip(path, { paths: { [path]: { place: "root", folder: true } } }, () => undefined);
  await view.act(async () => view.chip.focus());
  await view.until(() => view.card()?.querySelector(".cv-link-preview__open"));
  expect(view.card()?.textContent).toContain("src");
  expect(view.card()?.querySelector("pre, img")).toBeNull();
  expect(view.card()?.querySelector(".cv-link-preview__open")).not.toBeNull();
  expect(view.calls).toEqual([{ method: "link.preview", params: { path } }]);
  await view.done();
});

test("a host without link.preview keeps the plain file card and never asks for a thumbnail", async () => {
  const path = "/tmp/cmux-shots/before.png";
  const view = await renderChip(
    path,
    { paths: { [path]: { place: "outside", folder: false } }, policy: { outsideRoots: "open" } },
    // A host that doesn't know link.preview refuses it; it would still draw the image if asked.
    ({ method }) =>
      method === "link.preview"
        ? Promise.reject(
            Object.assign(new Error("Unsupported agent pane request: link.preview"), { code: "unsupported" }),
          )
        : method === "image.load"
          ? { src: PNG }
          : undefined,
  );
  await view.act(async () => view.chip.focus());
  await view.until(() => view.card()?.querySelector(".cv-link-preview__open"));
  const card = view.card()!;
  expect(card.textContent).toContain("before.png");
  expect(card.textContent).toContain(path);
  expect(card.querySelector("img, pre, .cv-path-preview__note")).toBeNull();
  expect(view.calls).toEqual([{ method: "link.preview", params: { path } }]);
  await view.done();
});

test("an image the host won't read as text still shows its thumbnail", async () => {
  const path = "/Users/you/src/atlas-web/shots/after.png";
  const refusal = Object.assign(new Error("not text"), { code: "link.path_invalid" });
  const view = await renderChip(path, { paths: { [path]: { place: "root", folder: false } } }, ({ method }) =>
    method === "link.preview" ? Promise.reject(refusal) : method === "image.load" ? { src: PNG } : undefined,
  );
  await view.act(async () => view.chip.focus());
  await view.until(() => view.card()?.querySelector("img"));
  expect(view.card()!.querySelector("img")?.getAttribute("src")).toBe(PNG);
  await view.done();
});

test("an image the host refuses to draw keeps the plain file card, never an empty thumbnail", async () => {
  const path = "/tmp/cmux-shots/before.png";
  const view = await renderChip(path, { paths: { [path]: { place: "outside", folder: false } } }, ({ method }) =>
    method === "image.load"
      ? Promise.reject(Object.assign(new Error("outside"), { code: "link.path_outside_roots" }))
      : {},
  );
  await view.act(async () => view.chip.focus());
  await view.until(() => view.card()?.querySelector(".cv-link-preview__open"));
  expect(view.card()!.querySelector("img, pre")).toBeNull();
  expect(view.calls.map((call) => call.method)).toEqual(["link.preview", "image.load"]);
  await view.done();
});

test("an image path that a text read would accept still shows no text", async () => {
  const path = "/tmp/cmux-shots/fake.png";
  const view = await renderChip(path, { paths: { [path]: { place: "root", folder: false } } }, ({ method }) =>
    method === "link.preview" ? { lines: ["not an image"], truncated: false } : undefined,
  );
  await view.act(async () => view.chip.focus());
  await view.until(() => view.calls.some((call) => call.method === "link.preview"));
  expect(view.card()!.querySelector("pre, img")).toBeNull();
  await view.done();
});

test("an image in a chat on another machine never asks the host for a thumbnail", async () => {
  const path = "/Users/you/shots/after.png";
  const view = await renderChip(path, { paths: { [path]: { place: "root", folder: false } } }, ({ method }) =>
    // A host that would draw a same-named file on this Mac if asked.
    method === "link.preview" ? { remote: true } : method === "image.load" ? { src: PNG } : undefined,
  );
  await view.act(async () => view.chip.focus());
  await view.until(() => view.card()?.querySelector(".cv-path-preview__note"));
  const card = view.card()!;
  expect(card.querySelector(".cv-path-preview__note")?.textContent).toBe(
    "This chat runs on another machine, so this file can't be previewed here",
  );
  expect(card.querySelector("img, pre")).toBeNull();
  expect(card.querySelector(".cv-link-preview__open")).toBeNull();
  expect(view.calls).toEqual([{ method: "link.preview", params: { path } }]);
  await view.done();
});

test("an unseeded chip in a chat on another machine stays a chip with the remote card", async () => {
  const path = "/home/agent/out/report.txt";
  // The host answers `link.inspect` itself here: no place for a remote chat's path, and remote.
  const view = await renderChip(path, {}, ({ method }) =>
    method === "link.inspect"
      ? { paths: {}, remote: true, policy: { outsideRoots: "open", remoteImages: "click" } }
      : method === "link.preview"
        ? { remote: true }
        : undefined,
  );
  await view.until(() => view.calls.some((call) => call.method === "link.inspect"));
  expect(view.calls.find((call) => call.method === "link.inspect")?.params).toEqual({ paths: [path], urls: [] });
  const chip = view.rootElement.querySelector<HTMLButtonElement>("button.cv-chip.is-path");
  expect(chip).not.toBeNull();
  expect(view.rootElement.querySelector(".cv-chip-plain")).toBeNull();
  await view.act(async () => chip!.focus());
  await view.until(() => view.card()?.querySelector(".cv-path-preview__note"));
  const card = view.card()!;
  expect(card.textContent).toContain("report.txt");
  expect(card.querySelector(".cv-link-preview__open")).toBeNull();
  expect(view.calls.some((call) => call.method === "image.load")).toBe(false);
  await view.done();
});

test("Open waits for the host's answer, so a remote folder's card never flashes it", async () => {
  const path = "/tmp/reports/";
  let answer: (value: unknown) => void = () => {};
  const view = await renderChip(path, { paths: { [path]: { place: "outside", folder: true } } }, ({ method }) =>
    method === "link.preview" ? new Promise((resolve) => (answer = resolve)) : undefined,
  );
  await view.act(async () => view.chip.focus());
  await view.until(() => view.calls.some((call) => call.method === "link.preview"));
  expect(view.card()).not.toBeNull();
  expect(view.card()!.querySelector(".cv-link-preview__open")).toBeNull();
  await view.act(async () => answer({ remote: true }));
  await view.until(() => view.card()?.querySelector(".cv-path-preview__note"));
  expect(view.card()!.textContent).toContain("reports");
  expect(view.card()!.querySelector(".cv-link-preview__open")).toBeNull();
  await view.done();
});

/// A host answer the test settles by hand.
function pending() {
  let settle: (value: unknown) => void = () => {};
  const promise = new Promise((resolve) => (settle = resolve));
  return { promise, settle };
}

test("a card opened again shows nothing from the last hover until this hover's answer arrives", async () => {
  const path = "/Users/you/shots/after.png";
  let next: ReturnType<typeof pending> | undefined;
  const view = await renderChip(path, { paths: { [path]: { place: "root", folder: false } } }, ({ method }) =>
    method === "link.preview" ? (next ? next.promise : {}) : method === "image.load" ? { src: PNG } : undefined,
  );
  await view.act(async () => view.chip.focus());
  await view.until(() => view.card()?.querySelector("img"));
  await view.act(async () => view.chip.blur());
  await view.until(() => !view.card());
  // The chat turned remote in between: this hover's answer is still out.
  next = pending();
  await view.act(async () => view.chip.focus());
  await view.until(() => view.calls.filter((call) => call.method === "link.preview").length === 2);
  expect(view.card()!.querySelector("img, pre, .cv-link-preview__open")).toBeNull();
  await view.act(async () => next!.settle({ remote: true }));
  await view.until(() => view.card()?.querySelector(".cv-path-preview__note"));
  expect(view.card()!.querySelector("img, .cv-link-preview__open")).toBeNull();
  await view.done();
});

test("a host that never answers falls back to the plain file card", async () => {
  const { setPathPreviewTimeout } = await import("../src/agent-session/acpmux/chips/PathHoverCard");
  setPathPreviewTimeout(1);
  const path = "/Users/you/shots/after.png";
  const view = await renderChip(path, { paths: { [path]: { place: "root", folder: false } } }, ({ method }) =>
    method === "link.preview" ? pending().promise : method === "image.load" ? { src: PNG } : undefined,
  );
  try {
    await view.act(async () => view.chip.focus());
    await view.until(() => view.card()?.querySelector(".cv-link-preview__open"));
    expect(view.card()!.querySelector(".cv-link-preview__open")).not.toBeNull();
    expect(view.card()!.querySelector("img, pre")).toBeNull();
    expect(view.calls.map((call) => call.method)).toEqual(["link.preview"]);
  } finally {
    setPathPreviewTimeout(undefined);
    await view.done();
  }
});

test("hovering out or unmounting while the host is asked clears its wait and sends nothing more", async () => {
  const path = "/Users/you/shots/after.png";
  for (const leave of ["hover-out", "unmount"] as const) {
    const answer = pending();
    const view = await renderChip(path, { paths: { [path]: { place: "root", folder: false } } }, ({ method }) =>
      method === "link.preview" ? answer.promise : method === "image.load" ? { src: PNG } : undefined,
    );
    const flush = () =>
      view.act(async () => {
        for (let turn = 0; turn < 5; turn += 1) await Promise.resolve();
      });
    jest.useFakeTimers();
    try {
      await view.act(async () => view.chip.focus());
      await flush();
      expect(view.calls.map((call) => call.method)).toEqual(["link.preview"]);
      // Hover-out closes the card after its grace; either way the 4 s wait must go with it.
      if (leave === "hover-out") await view.act(async () => (view.chip.blur(), jest.advanceTimersByTime(1000)));
      else await view.act(async () => view.unmount());
      await view.act(async () => jest.advanceTimersByTime(100));
      expect(view.card()).toBeNull();
      expect(jest.getTimerCount()).toBe(0);
      // The late answer arrives; its follow-up (an image's thumbnail) must not go out.
      answer.settle({});
      await flush();
      expect(view.calls.map((call) => call.method)).toEqual(["link.preview"]);
    } finally {
      jest.useRealTimers();
      await view.done();
    }
  }
});

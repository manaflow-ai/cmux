// Link and path chips in replies (decision D4): what a reader sees for a path or a URL, and what
// a click asks the host for.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-page://cmux.agent/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Markdown } = await import("../conversation/Markdown");
const { setChipHost } = await import("./host");

async function render(source: string) {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    return null;
  });
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(createElement(Markdown, null, source)));
  return {
    container,
    calls,
    unmount: async () => {
      await act(async () => root.unmount());
      setChipHost(undefined);
    },
  };
}

test("a file link is a chip: file icon, the link text, the full path in the tooltip; a click opens it in a tab", async () => {
  const { container, calls, unmount } = await render("See [the readme](/Users/ada/repo/README.md) first.");
  const chip = container.querySelector<HTMLButtonElement>(".cv-chip.is-path")!;
  expect(chip).not.toBeNull();
  expect(chip.title).toBe("/Users/ada/repo/README.md");
  expect(chip.querySelector(".cv-chip__label")?.textContent).toBe("the readme");
  expect(chip.querySelector("svg")).not.toBeNull();
  await act(async () => chip.click());
  expect(calls).toEqual([{ method: "file.open", params: { path: "/Users/ada/repo/README.md", where: "tab" } }]);
  await unmount();
});

test("a path in inline code is a chip named by its file; a line suffix is dropped for the open", async () => {
  const { container, calls, unmount } = await render("Fixed in `/Users/ada/repo/src/main.ts:42`.");
  const chip = container.querySelector<HTMLButtonElement>(".cv-chip.is-path")!;
  expect(chip.querySelector(".cv-chip__label")?.textContent).toBe("main.ts");
  expect(chip.title).toBe("/Users/ada/repo/src/main.ts");
  expect(container.querySelector("code")).toBeNull();
  await act(async () => chip.click());
  expect(calls[0]?.params).toEqual({ path: "/Users/ada/repo/src/main.ts", where: "tab" });
  await unmount();
});

test("a file:// link and a page type open in cmux's file pages (a tab), never in an outside app", async () => {
  const { container, calls, unmount } = await render("[report](file:///tmp/out/report.html)");
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-chip.is-path")!.click());
  expect(calls).toEqual([{ method: "file.open", params: { path: "/tmp/out/report.html", where: "tab" } }]);
  await unmount();
});

test("commands, globs and bare names in code stay code", async () => {
  const { container, unmount } = await render("Run `ls /tmp`, `rm -rf /tmp/x/*.log`, `README.md` and `/usr`.");
  expect(container.querySelector(".cv-chip")).toBeNull();
  expect(container.querySelectorAll("code").length).toBe(4);
  await unmount();
});

test("a secret on the deny list is plain text with no action", async () => {
  const { container, calls, unmount } = await render(
    "Keys: [key](/Users/ada/.ssh/id_ed25519), `/Users/ada/repo/.env.local` and `/Users/ada/certs/server.pem`.",
  );
  expect(container.querySelector(".cv-chip")).toBeNull();
  expect(container.textContent).toContain("/Users/ada/repo/.env.local");
  expect(container.querySelectorAll("button").length).toBe(0);
  expect(calls).toEqual([]);
  await unmount();
});

test("a web link is a chip: globe, the link text, the full URL in the tooltip, an ordinary link", async () => {
  const { container, unmount } = await render("Read [the docs](https://example.com/guide?x=1).");
  const chip = container.querySelector<HTMLAnchorElement>("a.cv-chip.is-web")!;
  expect(chip.getAttribute("href")).toBe("https://example.com/guide?x=1");
  expect(chip.title).toBe("https://example.com/guide?x=1");
  expect(chip.querySelector(".cv-chip__label")?.textContent).toBe("the docs");
  expect(chip.querySelector("svg")).not.toBeNull();
  await unmount();
});

test("a javascript: link still draws as its text", async () => {
  const { container, unmount } = await render("[click](javascript:alert(1))");
  expect(container.querySelector("a")).toBeNull();
  expect(container.querySelector(".cv-chip")).toBeNull();
  expect(container.textContent).toBe("click");
  await unmount();
});

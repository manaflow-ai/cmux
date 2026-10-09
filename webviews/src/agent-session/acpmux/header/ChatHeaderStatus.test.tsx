import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ChatHeaderStatus } = await import("./ChatHeaderStatus");

async function render(props: Parameters<typeof ChatHeaderStatus>[0]) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(createElement(ChatHeaderStatus, props)));
  return { container, unmount: () => act(async () => root.unmount()) };
}

// Round 1 (UI tournament): a retry reads as a warning, a lost or failed connection as an error, so the
// two are told apart without reading; a screen reader hears the reason, not only "Failed".
test("a connection problem shows its tone, and its label carries the detail", async () => {
  const { container, unmount } = await render({
    status: "Failed",
    detail: "the agent process exited with status 1",
    tone: "error",
  });
  const status = container.querySelector<HTMLElement>(".acpmux-status")!;
  expect(status.dataset.tone).toBe("error");
  expect(status.getAttribute("aria-label")).toBe("Failed: the agent process exited with status 1");
  await unmount();
});

test("a status without more detail is labelled by the status alone", async () => {
  const { container, unmount } = await render({ status: "Disconnected", detail: "Disconnected", tone: "error" });
  const status = container.querySelector<HTMLElement>(".acpmux-status")!;
  expect(status.hasAttribute("tabindex")).toBe(false);
  expect(status.getAttribute("aria-label")).toBe("Disconnected");
  await unmount();
});

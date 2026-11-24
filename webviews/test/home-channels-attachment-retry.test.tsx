// Leo, 2026-11-06: "why does it not retry this? The screenshots, or whatever, or any sort of
// attachment when it fails, like you can't simply just do nothing about it." A Home channel's
// upload and its image reads are tried again on its own; what still fails shows Retry.
import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
Object.assign(dom.window, {
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
});
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "File",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = new Map(keys.map((key) => [key, scope[key]]));
Object.assign(scope, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MouseEvent: dom.window.MouseEvent,
  KeyboardEvent: dom.window.KeyboardEvent,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => {
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom.window.close();
});

const { Composer } = await import("../src/pages/home-channels/Composer");
const { AttachmentContext, MessageAttachments } = await import("../src/pages/home-channels/AttachmentViews");
const { attachmentRetry } = await import("../src/pages/shared/attachmentRetry");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/home-channels/generated/strings.json")).default;

attachmentRetry.delaysMs = [0, 0, 0];
const strings = createStrings(table, ["en"]);
/// Yields macrotasks (the tries again wait 0 ms here) until `check` holds, or fails after 200.
const until = async (check: () => boolean) => {
  for (let turn = 0; turn < 200 && !check(); turn++)
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  expect(check()).toBe(true);
};
const part = (name: string) => ({ type: "attachment", hash: name, name, mimeType: "text/plain", byteCount: 1 });

async function composer(upload: (file: File) => Promise<unknown>) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => {
    root.render(
      <Composer
        strings={strings}
        placeholder="Message"
        label="Message"
        onSend={async () => true}
        attachments={{ service: { upload: (_c: string, file: File) => upload(file) } as never, conversation: "c1" }}
      />,
    );
  });
  const picker = container.querySelector<HTMLInputElement>("input[type=file]")!;
  Object.defineProperty(picker, "files", {
    configurable: true,
    value: [new dom.window.File(["x"], "shot.txt", { type: "text/plain" })],
  });
  await act(async () => {
    picker.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  });
  return { container, root };
}

test("an upload that fails for a moment is tried again on its own and lands", async () => {
  let tries = 0;
  const { container, root } = await composer(async (file) => {
    tries += 1;
    if (tries < 3) throw new Error("socket closed");
    return part(file.name);
  });
  await until(() => container.querySelector(".hc-tray-item.done") !== null);
  expect(tries).toBe(3);
  expect(container.querySelector(".hc-tray-item.done")).not.toBeNull();
  expect(container.querySelector(".hc-tray-item.failed")).toBeNull();
  await act(async () => root.unmount());
});

test("an upload that still fails shows Retry, and Retry lands it", async () => {
  let failing = true;
  let tries = 0;
  const { container, root } = await composer(async (file) => {
    tries += 1;
    if (failing) throw new Error("socket closed");
    return part(file.name);
  });
  await until(() => container.querySelector(".hc-tray-item.failed") !== null);
  expect(tries).toBe(4);
  const retry = container.querySelector<HTMLButtonElement>(".hc-tray-item.failed .hc-tray-retry");
  expect(retry?.textContent).toBe(strings.t("pending.retry"));
  failing = false;
  await act(async () => retry!.click());
  await until(() => container.querySelector(".hc-tray-item.done") !== null);
  expect(container.querySelector(".hc-tray-item.done")).not.toBeNull();
  await act(async () => root.unmount());
});

test("a sent image whose read fails is read again on its own, then its tile offers Retry", async () => {
  const container = dom.window.document.getElementById("root")!;
  let failing = true;
  let reads = 0;
  const service = {
    image: async () => {
      reads += 1;
      if (failing) throw new Error("socket closed");
      return "data:image/png;base64,AA==";
    },
    url: async () => "",
  };
  const image = { type: "attachment", hash: "h1", name: "shot.png", mimeType: "image/png", byteCount: 10 };
  const root = createRoot(container);
  await act(async () => {
    root.render(
      <AttachmentContext.Provider value={service as never}>
        <MessageAttachments conversation="c1" parts={[image as never]} strings={strings} />
      </AttachmentContext.Provider>,
    );
  });
  await until(() => container.querySelector(".hc-att-image.failed") !== null);
  expect(reads).toBe(4);
  const tile = container.querySelector<HTMLButtonElement>(".hc-att-image.failed")!;
  expect(tile.disabled).toBe(false);
  expect(tile.textContent).toContain(strings.t("pending.retry"));
  failing = false;
  await act(async () => tile.click());
  await until(() => container.querySelector(".hc-att-image img") !== null);
  expect(container.querySelector(".hc-att-image img")?.getAttribute("src")).toBe("data:image/png;base64,AA==");
  await act(async () => root.unmount());
});

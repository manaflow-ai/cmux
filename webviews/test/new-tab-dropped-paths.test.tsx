// The New Tab page takes a folder or a file no prompt block takes (a zip, a video) dropped from
// Finder: it has no upload, so these were only refused. On this Mac the host answers where each one
// is (`chat.attach.dropped`), and the first prompt carries them as links to those paths.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerAttachment, DroppedKind, LinkItem } from "../src/agent-session/acpmux/attachments";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>").window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

/// A dropped folder: WebKit hands a File whose bytes cannot be read.
function folder(name: string): File {
  const entry = new File([], name, { type: "" });
  Object.defineProperty(entry, "arrayBuffer", { value: () => Promise.reject(new Error("not a file")) });
  return entry;
}

test("a folder and a zip dropped on the New Tab page go with the prompt as links to where they are", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const asked: unknown[][] = [];
  const looked: [DroppedKind, string[]][] = [];
  const localPaths = async (kind: DroppedKind, files: File[]): Promise<LinkItem[]> => {
    looked.push([kind, files.map((each) => each.name)]);
    return [
      { path: "/Users/you/src/app/assets", folder: true },
      { path: "/Users/you/Downloads/build.zip", folder: false },
    ];
  };
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you/src/app"
        localPaths={localPaths}
        onAsk={(...args) => asked.push(args)}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );

  const files = [
    folder("assets"),
    new File([new Uint8Array([0x50, 0x4b, 0x03, 0xff])], "build.zip", { type: "application/zip" }),
  ];
  const drop = new window.Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(drop, "dataTransfer", { value: { files, types: ["Files"] } });
  await act(async () => {
    window.document.body.dispatchEvent(drop);
  });
  for (let tries = 0; tries < 500 && host.querySelectorAll(".acpmux-attachment-link").length < 2; tries += 1)
    await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(looked).toEqual([["drop", ["assets", "build.zip"]]]);
  expect([...host.querySelectorAll(".acpmux-attachment-link-name")].map((chip) => chip.textContent)).toEqual([
    "assets/",
    "build.zip",
  ]);
  // No refusal: nothing was left out.
  expect(host.querySelector("output.acpmux-attachment-note")).toBeNull();

  const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, "what is in these?");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  const send = host.querySelector<HTMLButtonElement>('button[aria-label="Send"]');
  await act(async () => send!.click());
  expect(asked.length).toBe(1);
  const attachments = asked[0]![5] as ComposerAttachment[];
  expect(attachments.map((chip) => [chip.kind, chip.path])).toEqual([
    ["link", "/Users/you/src/app/assets"],
    ["link", "/Users/you/Downloads/build.zip"],
  ]);
});

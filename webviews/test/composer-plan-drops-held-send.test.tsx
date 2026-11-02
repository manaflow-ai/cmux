// l10n-allow-file: synthetic file names for a behavioral regression.
// A prompt too large for one acpmux message waits for its images' originals still uploading, then
// goes with them as links (promptBudget.ts, #29500). Review of #29500 (Codex, round 3): a bare
// `/plan` sent meanwhile returned before the held send was dropped, so once the uploads ended the
// held send went on its own, with whatever the composer held then, and no key press.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { UploadResult } from "../src/agent-session/acpmux/cloudUploads";

const MIB = 1024 * 1024;
/// Each screenshot's preview: under the 1.5 MiB image budget, so twenty of them exceed the prompt's.
const PREVIEW_BYTES = 1.4 * MIB;

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "createImageBitmap",
  "OffscreenCanvas",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    // The engine's image decoder and canvas, which jsdom lacks (composer/imageWork.ts).
    createImageBitmap: async () => ({ width: 40, height: 30, close() {} }),
    OffscreenCanvas: class {
      constructor(
        public width: number,
        public height: number,
      ) {}
      getContext() {
        return { drawImage() {}, fillRect() {}, fillStyle: "" };
      }
      async convertToBlob({ type }: { type: string }) {
        return new Blob([new Uint8Array(PREVIEW_BYTES)], { type });
      }
    },
  });
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(async () => {
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 5_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await settle();
  }
}

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

test("a bare /plan drops a send waiting for originals: it never goes on its own once they are saved", async () => {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const modes: string[] = [];
  /// The batch upload of the screenshots' originals, answered when the test says.
  let finish: ((result: UploadResult) => void) | undefined;
  let names: string[] = [];
  const upload = (files: File[]) =>
    new Promise<UploadResult>((resolve) => {
      names = files.map((file) => file.name);
      finish = resolve;
    });
  const handle = createRef<ComposerHandle>();
  const snapshot = noChat([], {
    sessionId: "chat-a",
    summary: {
      sessionId: "chat-a",
      harness: "claude",
      cwd: "/Users/you/src/app",
      turnCount: 0,
      modes: {
        currentModeId: "default",
        availableModes: [
          { id: "default", name: "Default" },
          { id: "plan", name: "Plan" },
        ],
      },
    },
  });
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId="chat-a"
        chips={Chips}
        onSend={(text, attachments) => {
          sent.push({ text, attachments: attachments ?? [] });
          return true;
        }}
        onMode={(mode) => modes.push(mode)}
        upload={upload}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
      />,
    ),
  );
  await until(() => !!host.querySelector('[role="combobox"]'), "the editor");
  const field = host.querySelector<HTMLElement>('[role="combobox"]')!;

  // Twenty screenshots pasted: each is its preview chip at once while its original still uploads.
  const files = Array.from({ length: 20 }, (_, index) => new File(["png"], `Shot ${index}.png`, { type: "image/png" }));
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { files, types: ["Files"], getData: () => "" },
  });
  await act(async () => {
    field.dispatchEvent(event);
  });
  const chips = () => handle.current!.wakeState().attachments ?? [];
  await until(() => chips().length === 20 && finish !== undefined, "twenty screenshot chips and their upload");

  // Send: twenty previews exceed one message, so it waits for the originals.
  await act(async () => {
    handle.current!.send();
  });
  await settle();
  expect(sent).toHaveLength(0);

  // A bare /plan: the mode toggles and nothing is sent.
  await act(async () => handle.current!.prefill("/plan"));
  await settle();
  await act(async () => {
    handle.current!.send();
  });
  await settle();
  expect(modes).toEqual(["plan"]);
  expect(sent).toHaveLength(0);

  // The originals are saved. The held send was dropped by /plan: nothing goes without a key press.
  await act(async () => finish!({ paths: names.map((name) => `/Users/you/.cmux/uploads/${name}`) }));
  await settle();
  await settle();
  expect(chips().every((chip) => chip.originalPath)).toBe(true);
  expect(sent).toHaveLength(0);
});

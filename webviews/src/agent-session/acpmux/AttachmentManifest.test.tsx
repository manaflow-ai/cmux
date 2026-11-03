// l10n-allow-file: synthetic attachment records and test assertions.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AttachmentManifestContents } from "./AttachmentManifest";
import {
  attachmentManifestPage,
  type AttachmentManifestPage,
  type AttachmentManifestReader,
  type UploadManifest,
} from "./attachmentManifest";
import { FileAttachment } from "./FileAttachment";
import { normalizePromptContentPart, recordedPromptParts } from "./inlinePrompt";
import { recordedFiles } from "./conversation/UserBubble";
import { heldFiles } from "./conversation/QueuedMessageCard";
import { TurnActionsContext } from "./conversation/turnActions";

// Base UI may finish focus cleanup after a test restores its window.
globalThis.requestAnimationFrame ??= (callback) => setTimeout(() => callback(0), 0) as unknown as number;
globalThis.cancelAnimationFrame ??= (id) => clearTimeout(id);

const MANIFEST: UploadManifest = {
  type: "resource_link",
  uri: "file:///session/manifest/9001-attachments.jsonl",
  name: "9001-attachments.jsonl",
  mimeType: "application/x-ndjson",
  _meta: {
    acpmux: {
      uploadManifest: {
        uploadId: "m-1",
        fileName: "9001-attachments.jsonl",
        proof: "secret-proof",
      },
    },
  },
};
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "MouseEvent",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode) {
  if (!dom) {
    dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", {
      url: "http://localhost/",
      pretendToBeVisual: true,
    });
    for (const key of KEYS) saved.set(key, scope[key]);
    Object.assign(scope, {
      window: dom.window,
      document: dom.window.document,
      navigator: dom.window.navigator,
      Node: dom.window.Node,
      HTMLElement: dom.window.HTMLElement,
      Element: dom.window.Element,
      MouseEvent: dom.window.MouseEvent,
      getComputedStyle: dom.window.getComputedStyle,
      IS_REACT_ACT_ENVIRONMENT: true,
    });
    root = createRoot(document.querySelector("main")!);
  }
  await act(async () => root!.render(node));
}

function contents(read: AttachmentManifestReader, sessionId = "s-1") {
  return (
    <TurnActionsContext.Provider value={{ attachmentManifestSession: sessionId, attachmentManifestPage: read }}>
      <AttachmentManifestContents manifest={MANIFEST} />
    </TurnActionsContext.Provider>
  );
}
function button(text: string): HTMLButtonElement {
  return [...document.querySelectorAll("button")].find((button) => button.textContent === text)!;
}
const entry = (index: number) => ({
  blockIndex: index * 2 + 1,
  block: {
    type: "resource_link" as const,
    uri: `file:///session/file-${index}.bin`,
    name: `file-${index}.bin`,
    size: 8_000_000,
  },
  displayPart: { kind: "file", name: `original-${index}.bin`, source: { name: "Screenshot" } },
});
const page = (start: number, count = 80): AttachmentManifestPage => {
  const end = Math.min(9001, start + count);
  return {
    attachments: Array.from({ length: end - start }, (_, index) => entry(start + index)),
    hasMore: end < 9001,
    manifestOffset: end * 512,
  };
};

test("9,001 attachments reach the final visible entry in order with one page rendered", async () => {
  const calls: number[] = [];
  const read: AttachmentManifestReader = async (sessionId, manifest, offset) => {
    expect(sessionId).toBe("s-1");
    expect(manifest).toBe(MANIFEST);
    calls.push(offset);
    return page(offset / 512);
  };
  await render(contents(read));
  expect(calls).toEqual([0]); // Opening fetches one page only.
  const seen: number[] = [];
  for (let start = 0; start < 9001; start += 80) {
    const rows = [...document.querySelectorAll<HTMLElement>("[data-block-index]")];
    expect(rows.length).toBeLessThanOrEqual(80);
    expect(rows[0]!.textContent).toContain(`original-${start}.bin`);
    expect(rows[0]!.textContent).toContain("From Screenshot");
    seen.push(...rows.map((row) => Number(row.dataset.blockIndex)));
    if (start + 80 < 9001) await act(async () => button("Next").click());
  }
  expect(seen).toEqual(Array.from({ length: 9001 }, (_, index) => index * 2 + 1));
  expect(document.body.textContent).toContain("original-9000.bin");
  expect(button("Next").disabled).toBe(true);
  expect(calls).toHaveLength(Math.ceil(9001 / 80));
  await act(async () => button("Previous").click());
  expect(calls.at(-1)).toBe(8880 * 512);
  expect(document.querySelector("[data-block-index]")?.textContent).toContain("original-8880.bin");
}, 30_000);

test("a failed page is retryable without skipping entries", async () => {
  let calls = 0;
  const read: AttachmentManifestReader = async () => {
    if (++calls === 1) throw new Error("offline");
    return page(0);
  };
  await render(contents(read));
  expect(document.querySelectorAll("[data-block-index]")).toHaveLength(0);
  expect(document.body.textContent).toContain("Couldn't load attachments");
  expect(button("Next").disabled).toBe(true);
  await act(async () => button("Retry").click());
  expect(calls).toBe(2);
  expect(document.querySelectorAll("[data-block-index]")).toHaveLength(80);
});

test("changing session ignores a stale page; unmounting does not start more reads", async () => {
  let finish: (page: AttachmentManifestPage) => void = () => {};
  const calls: string[] = [];
  const read: AttachmentManifestReader = async (sessionId) => {
    calls.push(sessionId);
    return sessionId === "s-1"
      ? new Promise<AttachmentManifestPage>((resolve) => {
          finish = resolve;
        })
      : page(8000);
  };
  await render(contents(read));
  await render(contents(read, "s-2"));
  await act(async () => finish(page(0)));
  expect(document.querySelector("[data-block-index]")?.textContent).toContain("original-8000.bin");
  expect(document.body.textContent).not.toContain("original-0.bin");
  await act(async () => root!.unmount());
  root = undefined;
  expect(calls).toEqual(["s-1", "s-2"]);
});

test("malformed/non-advancing pages fail without dropping individual entries", () => {
  expect(() => attachmentManifestPage({ ...page(0), manifestOffset: 0 }, 0)).toThrow();
  expect(() => attachmentManifestPage({ ...page(0), attachments: [entry(0), { blockIndex: 3 }] }, 0)).toThrow();
});

test("persisted, inline and held files retain the exact authenticated manifest link", () => {
  const raw = {
    kind: "file",
    name: "9001-attachments.jsonl",
    uri: MANIFEST.uri,
    uploadManifest: MANIFEST,
  };
  const part = normalizePromptContentPart(raw);
  expect(part).toEqual(raw);
  const parts = recordedPromptParts({ inlineParts: [raw] });
  expect(recordedFiles(parts)?.[0]?.uploadManifest).toBe(MANIFEST);
  expect(heldFiles(parts)[0]?.uploadManifest).toBe(MANIFEST);
});

test("ordinary files stay quiet; manifest files open the paged viewer on demand", async () => {
  const calls: number[] = [];
  const read: AttachmentManifestReader = async (_session, _manifest, offset) => {
    calls.push(offset);
    return page(0);
  };
  await render(
    <TurnActionsContext.Provider value={{ attachmentManifestSession: "s-1", attachmentManifestPage: read }}>
      <FileAttachment file={{ name: "ordinary.bin" }} />
      <FileAttachment file={{ name: "9001-attachments.jsonl", uploadManifest: MANIFEST }} />
    </TurnActionsContext.Provider>,
  );
  expect(document.querySelectorAll(".acpmux-manifest-trigger")).toHaveLength(1);
  expect(calls).toEqual([]);
  await act(async () => document.querySelector<HTMLButtonElement>(".acpmux-manifest-trigger")!.click());
  expect(document.querySelector('[role="dialog"]')).not.toBeNull();
  expect(calls).toEqual([0]);
  expect(document.querySelectorAll("[data-block-index]")).toHaveLength(80);
  await act(async () => document.querySelector<HTMLButtonElement>('[aria-label="Close"]')!.click());
  expect(document.querySelectorAll("[data-block-index]")).toHaveLength(0);
});

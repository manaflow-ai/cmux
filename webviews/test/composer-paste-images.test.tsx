// Leo 2026-10-20: two images copied in Chrome and pasted into the composer showed as chips and also
// full size in the field, as `![Screenshot · 778×696](data:image/png;base64,…)`; the prompt went out
// with that text, the bubble showed pages of base64 and the chat's compaction failed. A pasted image
// is an attachment atom: only its thumbnail is rendered, its data never becomes prompt text
// (it goes as an ACP image block), and a bubble never draws the data URI as text.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, type ComponentProps, type RefObject } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { promptBlocks, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { liftInlineImages, withoutDataUris } from "../src/agent-session/acpmux/inlineImages";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";

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
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
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
    ...imageEngine(),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

// A PNG's signature and header, padded past a spacer image's size: a copied screenshot.
const PNG = Uint8Array.from([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0,
  0,
  0,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  // Its size, 640x480 (the composer reads it before it decodes the picture), then filler.
  0,
  0,
  2,
  0x80,
  0,
  0,
  1,
  0xe0,
  ...Array(504).fill(7),
]);
/// The engine's image decoder and canvas, which jsdom lacks. Every attached image is decoded and
/// re-encoded to strip its metadata (composer/imageWork.ts prepareImage, since #24652); with no
/// engine to draw it is no image. This one reads the file's bytes as a real decode does, and each
/// canvas encodes back to the screenshot's own PNG.
function imageEngine() {
  return {
    createImageBitmap: async (source: Blob) => {
      await source.arrayBuffer();
      return { width: 640, height: 480, close() {} };
    },
    OffscreenCanvas: class {
      constructor(
        public width: number,
        public height: number,
      ) {}
      getContext() {
        return { drawImage() {}, fillRect() {}, fillStyle: "" };
      }
      async convertToBlob({ type }: { type: string }) {
        return new Blob([PNG], { type });
      }
    },
  };
}

const pngBase64 = btoa(String.fromCharCode(...PNG));
const dataUri = `data:image/png;base64,${pngBase64}`;
/// What Chrome's Copy Image (or a copied transcript image) puts on the clipboard beside the file.
const imageHtml = (count: number) =>
  Array.from({ length: count }, (_, index) => `<img src="${dataUri}" alt="Screenshot · 778×69${index}">`).join("");

/// Yields to React until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
}

/// The open composer's handle, for `paste` to read its chips.
let opened: RefObject<ComposerHandle | null> | undefined;

let composerCount = 0;
type ComposerProps = ComponentProps<typeof import("../src/agent-session/acpmux/Composer").Composer>;

/// `extra`: more props; `newChat`, a chat not started yet (no session id), whose text goes to
/// `onUnsentDraft`.
async function openComposer(
  sent: { text: string; attachments: ComposerAttachment[] }[] = [],
  extra: Partial<ComposerProps> = {},
  newChat = false,
) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const handle = createRef<ComposerHandle>();
  opened = handle;
  const sessionId = newChat ? undefined : `chat-${++composerCount}`;
  const snapshot = noChat(
    [],
    sessionId ? { sessionId, summary: { sessionId, harness: "codex", cwd: "/Users/you/src/app", turnCount: 0 } } : {},
  );
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        {...(sessionId ? { sessionId } : {})}
        chips={Chips}
        onSend={(text, attachments) => {
          sent.push({ text, attachments: attachments ?? [] });
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
        {...extra}
      />,
    ),
  );
  return handle;
}

const field = () => host.querySelector<HTMLElement>('[role="combobox"]')!;
const markdownField = () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;

/// Pastes on the prompt field as WebKit delivers it: one ClipboardEvent with the clipboard's data.
async function paste(clipboard: { files?: File[]; html?: string; plain?: string }) {
  const data = {
    files: clipboard.files ?? [],
    types: [
      ...(clipboard.files?.length ? ["Files"] : []),
      ...(clipboard.html ? ["text/html"] : []),
      ...(clipboard.plain ? ["text/plain"] : []),
    ],
    getData: (type: string) =>
      type === "text/html" ? (clipboard.html ?? "") : type === "text/plain" ? (clipboard.plain ?? "") : "",
  };
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: data });
  await act(async () => {
    field().dispatchEvent(event);
  });
  // The chips are read from the files after the event, all of one paste's at once.
  await until(() => (opened!.current!.wakeState().attachments ?? []).length > 0, "the pasted chips");
}

const screenshot = (index: number) => new File([PNG], "image.png", { type: "image/png", lastModified: index });

test("pasting two copied images puts two attachment atoms in the prompt", async () => {
  const composer = await openComposer();
  await paste({ files: [screenshot(1), screenshot(2)], html: imageHtml(2) });
  const chips = composer.current!.wakeState().attachments ?? [];
  expect(chips.map((chip) => chip.kind)).toEqual(["image", "image"]);
  expect(chips.every((chip) => chip.data === pngBase64)).toBe(true);
  await until(() => field().querySelectorAll("[data-inline-attachment] img").length === 2, "inline thumbnails");
});

test("an image copied as HTML alone (no file on the clipboard) still comes in as a chip, its text as text", async () => {
  const composer = await openComposer();
  await paste({ html: `<p>look at these</p>${imageHtml(2)}`, plain: "look at these" });
  expect((composer.current!.wakeState().attachments ?? []).map((chip) => chip.kind)).toEqual(["image", "image"]);
  await until(() => field().querySelectorAll("[data-inline-attachment] img").length === 2, "inline thumbnails");
  expect(field().textContent).toContain("look at these");
});

test("a pasted image goes to the agent as an image block; the prompt's text has no data: URI", async () => {
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent);
  await paste({ files: [screenshot(1), screenshot(2)], html: imageHtml(2), plain: "" });
  await act(async () => {
    composer.current!.send();
  });
  expect(sent).toHaveLength(1);
  const blocks = promptBlocks(sent[0]!.text, sent[0]!.attachments);
  expect(blocks.filter((block) => block.type === "image")).toHaveLength(2);
  expect(JSON.stringify(blocks.filter((block) => block.type === "text"))).not.toContain("data:");
  expect(sent[0]!.text).not.toContain("data:");
});

test("a markdown data: image already written into a prompt's text goes as an image block, never as text", () => {
  const typed = `![Screenshot · 778×696](${dataUri} "Screenshot · 778×696")what the heck`;
  const blocks = promptBlocks(typed, []);
  expect(blocks.filter((block) => block.type === "text")).toEqual([{ type: "text", text: "what the heck" }]);
  expect(
    blocks.filter((block) => block.type === "image").map((block) => (block.type === "image" ? block.data : "")),
  ).toEqual([pngBase64]);
  // A title right after the base64, with no space (as Leo's prompt had), is part of the image.
  expect(liftInlineImages(`![a](${dataUri}"a")ok`).text).toBe("ok");
});

test("a data: URI written as text stays as written: in code, a source map, a CSS url(), an SVG", () => {
  const written = [
    "//# sourceMappingURL=data:application/json;base64,eyJ2IjozfQ==",
    "```css",
    `.logo { background: url(${dataUri}); }`,
    `![in a fence](${dataUri})`,
    "```",
    `Inline \`![code](${dataUri})\` stays.`,
    "![icon](data:image/svg+xml;base64,PHN2Zy8+)",
    "  indented, with trailing spaces  ",
  ].join("\n");
  expect(liftInlineImages(written)).toEqual({ text: written, attachments: [] });
  expect(promptBlocks(written, [])).toEqual([{ type: "text", text: written }]);
  // Lifting one image leaves the rest of the prompt as typed.
  const mixed = `  keep this\n\n![shot](${dataUri})\n\n\`${dataUri}\`  `;
  expect(liftInlineImages(mixed).text).toBe(`  keep this\n\n\n\n\`${dataUri}\`  `);
});

test("re-dropping the same local link replaces the chip instead of duplicating it", async () => {
  const { appendAttachments } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  const link = (name: string, path: string): ComposerAttachment => ({
    id: `link:${path}`,
    kind: "link",
    name,
    mimeType: "",
    size: 0,
    path,
  });
  const first = link("assets/", "/Users/you/assets");
  const replacement = link("assets/", "/Users/you/assets");
  const other = link("other/", "/Users/you/other");
  expect(appendAttachments([first], [replacement, other])).toEqual([replacement, other]);
});

test("re-attaching design selection chips replaces both stable ids", async () => {
  const { appendAttachments } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const selection = {
    id: "card-1",
    name: "Card",
    text: "hello",
    image: { mimeType: "image/png", data: "AA==" },
  };
  const chips = designSelectionChips(selection);
  expect(appendAttachments(appendAttachments([], chips), chips)).toEqual(chips);
});

test("attachment intake wires local link deduplication through its hook state", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useAttachmentIntake } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  let held: ComposerAttachment[] = [];
  function Field() {
    const result = useAttachmentIntake({
      allowImages: true,
      pasteTarget: () => undefined,
      localPaths: async (_kind, files) => files.map(() => ({ path: "/Users/you/assets", folder: true })),
    });
    held = result.attachments;
    return <output data-count={held.length} />;
  }
  root ??= createRoot(host);
  await act(async () => root!.render(<Field />));
  const files = [new File([], "assets", { type: "" }), new File([], "assets-copy", { type: "" })];
  for (const file of files)
    Object.defineProperty(file, "arrayBuffer", {
      value: () => Promise.reject(new Error("folder")),
    });
  const event = new dom.window.Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "dataTransfer", { value: { files, types: ["Files"] } });
  await act(async () => {
    host.dispatchEvent(event);
  });
  await new Promise<void>((resolve, reject) => {
    if (host.querySelector('output[data-count="1"]')) return resolve();
    let frames = 0;
    const observer = new MutationObserver(() => {
      if (host.querySelector('output[data-count="1"]')) {
        observer.disconnect();
        resolve();
      }
    });
    const check = () => {
      if (host.querySelector('output[data-count="1"]')) {
        observer.disconnect();
        resolve();
      } else if (++frames < 120) requestAnimationFrame(check);
      else {
        observer.disconnect();
        reject(new Error("attachment intake did not render a deduplicated link"));
      }
    };
    observer.observe(host, { childList: true, subtree: true, attributes: true });
    requestAnimationFrame(check);
  });
  await act(async () => {});
  expect(held.map((chip) => chip.path)).toEqual(["/Users/you/assets"]);
});

test("a file chosen in + > Attach files asks the host where it came from, and its chip keeps the answer", async () => {
  const asked: unknown[] = [];
  const shot = { name: "Screenshot", bundleId: "com.apple.screenshot.launcher" };
  const actions = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => unknown>;
  };
  actions.cmuxAcpmuxActions = {
    "chat.attach.source": (params) => {
      asked.push(params);
      return { sources: [shot] };
    },
  };
  try {
    const composer = await openComposer();
    const input = host.querySelector<HTMLInputElement>("input.acpmux-attach-input")!;
    const file = new File([PNG], "Screenshot 2026-10-29 at 10.14.02.png", { type: "image/png" });
    // What WebKit does once the person picks in the open panel: the input holds the files, then `change`.
    Object.defineProperty(input, "files", { value: [file], configurable: true });
    await act(async () => {
      input.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
    });
    await until(
      () => composer.current!.wakeState().attachments?.[0]?.source !== undefined,
      "the chosen screenshot's chip with its source",
    );
    // Asked as a pick, never as a drop or paste: the host answers from the panel's own record.
    expect(asked).toEqual([
      { kind: "choose", names: ["Screenshot 2026-10-29 at 10.14.02.png"], gestureAt: expect.any(Number) },
    ]);
    expect(composer.current!.wakeState().attachments?.map((chip) => chip.source)).toEqual([shot]);
  } finally {
    delete actions.cmuxAcpmuxActions;
  }
});

// A ready file never waits for where it came from: the source is a label, so a slow host answer
// (up to its 1.5 s deadline) must not hold the chip, or a send, behind it. The answer, when it comes,
// is added to the chip already staged.
test("a slow source answer never holds a ready chip; the source is added when it comes", async () => {
  const shot = { name: "Screenshot", bundleId: "com.apple.screenshot.launcher" };
  let answer: (value: { sources: unknown[] }) => void = () => {};
  const actions = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => unknown>;
  };
  actions.cmuxAcpmuxActions = {
    "chat.attach.source": () => new Promise((resolve) => (answer = resolve)),
  };
  try {
    const composer = await openComposer();
    const input = host.querySelector<HTMLInputElement>("input.acpmux-attach-input")!;
    const file = new File([PNG], "Screenshot 2026-10-29 at 10.14.02.png", { type: "image/png" });
    Object.defineProperty(input, "files", { value: [file], configurable: true });
    const picked = performance.now();
    await act(async () => {
      input.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
    });
    // The host has not answered: the chip is in, with no source yet, well before the lookup's
    // 1.5 s deadline (SOURCES_DEADLINE_MS) could have let it through.
    await until(() => (composer.current!.wakeState().attachments ?? []).length > 0, "the chip, before the answer");
    expect(performance.now() - picked).toBeLessThan(750);
    expect(composer.current!.wakeState().attachments?.map((chip) => chip.source)).toEqual([undefined]);
    await act(async () => answer({ sources: [shot] }));
    await until(
      () => composer.current!.wakeState().attachments?.[0]?.source !== undefined,
      "the late source on the staged chip",
    );
    expect(composer.current!.wakeState().attachments?.map((chip) => chip.source)).toEqual([shot]);
  } finally {
    delete actions.cmuxAcpmuxActions;
  }
});

// Review (Codex): a loading chip cancelled and brought back by an undo is read again under its id
// while its first read still runs. That stale read ending (here a failed upload) must leave the new
// read's chip alone: only the read that owns the id settles it.
test("an undone cancel's chip is settled by its new read, never by the cancelled one", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useAttachmentIntake } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  const answers: ((result: { paths: string[] } | { error: string }) => void)[] = [];
  let intake!: ReturnType<typeof useAttachmentIntake>;
  function Field() {
    intake = useAttachmentIntake({
      allowImages: true,
      pasteTarget: () => undefined,
      upload: () => new Promise((resolve) => answers.push(resolve)),
    });
    return null;
  }
  root ??= createRoot(host);
  await act(async () => root!.render(<Field />));
  const file = new File([new Uint8Array(64)], "notes.bin", { type: "application/octet-stream" });
  await act(async () => void intake.attach([file], true));
  await until(() => answers.length === 1, "the first upload");
  const id = intake.pending[0]!.id;
  // Its x, then an undo that brings its node back: the file is read again under the same id.
  await act(async () => intake.cancel(id));
  expect(intake.pending).toEqual([]);
  let revived = false;
  await act(async () => {
    revived = intake.revive(id);
  });
  expect(revived).toBe(true);
  await until(() => answers.length === 2, "the second upload");
  // The cancelled read's upload fails: the revived chip is still loading, not failed.
  await act(async () => answers[0]!({ error: "The upload failed." }));
  for (let turn = 0; turn < 5; turn += 1)
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  expect(intake.pending.map((chip) => [chip.id, chip.failed])).toEqual([[id, undefined]]);
  // The revived read's upload lands: one attachment, under the id.
  await act(async () => answers[1]!({ paths: ["/tmp/notes.bin"] }));
  await until(() => intake.attachments.length === 1, "the revived attachment");
  expect(intake.pending).toEqual([]);
  expect(intake.attachments.map((chip) => [chip.id, chip.path])).toEqual([[id, "/tmp/notes.bin"]]);
});

// Review (Codex): a huge paste's file is made a slice per task (pastedText.ts pastedTextFile), so its
// chip can be cancelled before its bytes exist. An undo then brings it back and reads it once they
// are, rather than leaving the text with nothing.
test("an undone cancel of a file still being made reads it once its bytes are made", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useAttachmentIntake } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  let intake!: ReturnType<typeof useAttachmentIntake>;
  function Field() {
    intake = useAttachmentIntake({
      allowImages: true,
      pasteTarget: () => undefined,
      upload: async (files) => ({ paths: files.map((file) => `/tmp/${file.name}`) }),
    });
    return null;
  }
  root ??= createRoot(host);
  await act(async () => root!.render(<Field />));
  let made!: (file: File) => void;
  const bytes = new Promise<File>((resolve) => {
    made = resolve;
  });
  await act(async () => void intake.attach([{ name: "Pasted text.txt", type: "text/plain", file: bytes }], true));
  const id = intake.pending[0]!.id;
  await act(async () => intake.cancel(id));
  let revived = false;
  await act(async () => {
    revived = intake.revive(id);
  });
  expect(revived).toBe(true);
  expect(intake.pending.map((chip) => [chip.id, chip.name])).toEqual([[id, "Pasted text.txt"]]);
  await act(async () => made(new File(["a".repeat(64)], "Pasted text.txt", { type: "text/plain" })));
  await until(() => intake.attachments.length === 1, "the revived attachment");
  expect(intake.pending).toEqual([]);
  expect(intake.attachments.map((chip) => [chip.id, chip.path])).toEqual([[id, "/tmp/Pasted text.txt"]]);
});

test("an image copied as HTML into a plain text field comes in as a chip and the text still goes in", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useAttachmentIntake } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  let held: ComposerAttachment[] = [];
  function Field() {
    const { attachments } = useAttachmentIntake({
      allowImages: true,
      pasteTarget: () => ({ uploads: false }),
    });
    held = attachments;
    return <textarea aria-label="Prompt" />;
  }
  root ??= createRoot(host);
  await act(async () => root!.render(<Field />));
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: {
      files: [],
      types: ["text/html", "text/plain"],
      getData: (type: string) =>
        type === "text/html"
          ? `<p>see this</p>${imageHtml(1)}<img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">`
          : "see this",
    },
  });
  await act(async () => {
    host.querySelector("textarea")!.dispatchEvent(event);
  });
  await until(() => held.length > 0, "the pasted chip");
  // The textarea's own paste still inserts the text; the spacer GIF is no chip.
  expect(event.defaultPrevented).toBe(false);
  expect(held.map((chip) => chip.kind)).toEqual(["image"]);
});

test("a prompt copied from a bubble with `![…](data:…)` text pastes as an attachment atom beside its text", async () => {
  const composer = await openComposer();
  await paste({ plain: `![Screenshot · 778×696](${dataUri} "Screenshot · 778×696")what the heck` });
  expect((composer.current!.wakeState().attachments ?? []).map((chip) => chip.kind)).toEqual(["image"]);
  await until(() => Boolean(field().querySelector("[data-inline-attachment] img")), "inline thumbnail");
  expect(field().textContent).toContain("what the heck");
});

test("the same text pasted into a plain text field leaves its text there without the image", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useAttachmentIntake } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  let held: ComposerAttachment[] = [];
  function Field() {
    const { attachments } = useAttachmentIntake({
      allowImages: true,
      pasteTarget: () => ({ uploads: false }),
    });
    held = attachments;
    return <textarea aria-label="Prompt" defaultValue="see: " />;
  }
  root ??= createRoot(host);
  await act(async () => root!.render(<Field />));
  const textarea = host.querySelector("textarea")!;
  textarea.setSelectionRange(5, 5);
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: {
      files: [],
      types: ["text/plain"],
      getData: (type: string) => (type === "text/plain" ? `![a](${dataUri}) ok` : ""),
    },
  });
  await act(async () => {
    textarea.dispatchEvent(event);
  });
  await until(() => held.length > 0, "the pasted chip");
  expect(event.defaultPrevented).toBe(true);
  expect(textarea.value).toBe("see:  ok");
  expect(held.map((chip) => chip.kind)).toEqual(["image"]);
});

test("odd input stays fast: an unclosed image before a long run of spaces, a long run of backticks", () => {
  const started = performance.now();
  liftInlineImages(`![a](${dataUri}${" ".repeat(200_000)}x`);
  liftInlineImages(`${"`".repeat(200_000)}\n![a](${dataUri})`);
  withoutDataUris(`![a](${dataUri}${" ".repeat(200_000)}x`, "Image");
  expect(performance.now() - started).toBeLessThan(2_000);
});

test("a bubble never draws a data: URI: each image reads as its name", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
  const row: AcpmuxRow = {
    id: "user-1",
    version: 1,
    at: Date.now(),
    kind: "user",
    seq: 1,
    text: `![Screenshot · 778×696](${dataUri} "Screenshot · 778×696")what the heck, and ${dataUri}`,
  };
  root ??= createRoot(host);
  await act(async () => root!.render(<UserBubble row={row} text={row.text ?? ""} />));
  const bubble = host.querySelector(".cv-user__bubble")!;
  expect(bubble.textContent).not.toContain("data:");
  expect(bubble.textContent).not.toContain(pngBase64);
  expect(bubble.textContent).toContain("[Screenshot · 778×696]what the heck, and [Image]");
  expect(withoutDataUris("no images here", "Image")).toBe("no images here");
});

test("inline images keep the text on both sides in the sent prompt", async () => {
  const { inlineToken } = await import("../src/agent-session/acpmux/attachments");
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent);
  const image: ComposerAttachment = {
    id: "between",
    kind: "image",
    name: "image.png",
    mimeType: "image/png",
    size: PNG.length,
    data: pngBase64,
  };
  await act(async () => composer.current!.restore(`before ${inlineToken(image.id)} after`, [image]));
  await until(() => Boolean(field().querySelector("[data-inline-attachment] img")), "restored inline image");
  await act(async () => composer.current!.send());
  const blocks = promptBlocks(sent[0]!.text, sent[0]!.attachments);
  expect(blocks.map((block) => block.type)).toEqual(["text", "image", "text"]);
  expect(blocks[0]).toEqual({ type: "text", text: "before " });
  expect(blocks[2]).toEqual({ type: "text", text: " after" });
});

// Review of #26545: a new chat's unsent draft (`chat.unsentDraft`) is the person's words only. An
// attachment's token is the composer's, and the host keeps no attachment with the text, so a token
// left in it came back after a relaunch as raw U+FFFC text in the prompt.
const MARK = "\uFFFC";

test("a new chat's unsent draft leaves out the token of an attachment still uploading", async () => {
  const drafts: string[] = [];
  // The host's upload never answers: the file stays a placeholder in the text.
  const upload = () => new Promise<never>(() => {});
  const composer = await openComposer([], { onUnsentDraft: (text) => void drafts.push(text), upload }, true);
  await act(async () => composer.current!.restore("see", []));
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  const archive = new File([new Uint8Array(64)], "notes.bin", { type: "application/octet-stream" });
  Object.defineProperty(event, "clipboardData", {
    value: { files: [archive], types: ["Files"], getData: () => "" },
  });
  await act(async () => {
    field().dispatchEvent(event);
  });
  await until(() => Boolean(field().querySelector("[data-inline-attachment]")), "the placeholder in the text");
  await act(async () => composer.current!.settleDraft());
  expect(drafts.at(-1)).toBe("see");
  for (const draft of drafts) expect(draft).not.toContain(MARK);
});

test("settling a new chat's draft sends its words without its attachments' tokens", async () => {
  const { inlineToken } = await import("../src/agent-session/acpmux/attachments");
  const drafts: string[] = [];
  const composer = await openComposer([], { onUnsentDraft: (text) => void drafts.push(text) }, true);
  const image: ComposerAttachment = {
    id: "settled",
    kind: "image",
    name: "image.png",
    mimeType: "image/png",
    size: PNG.length,
    data: pngBase64,
  };
  await act(async () => composer.current!.restore(`before ${inlineToken(image.id)} after`, [image]));
  await until(() => Boolean(field().querySelector("[data-inline-attachment] img")), "restored inline image");
  await act(async () => composer.current!.settleDraft());
  expect(drafts.at(-1)).toBe("before  after");
  for (const draft of drafts) expect(draft).not.toContain(MARK);
});

test("a chat's draft read before its kept attachments places them once they come", async () => {
  const { inlineToken } = await import("../src/agent-session/acpmux/attachments");
  const image: ComposerAttachment = {
    id: "kept-later",
    kind: "image",
    name: "image.png",
    mimeType: "image/png",
    size: PNG.length,
    data: pngBase64,
  };
  const composer = await openComposer([], { draft: `look ${inlineToken(image.id)} here` });
  await until(() => field().textContent?.includes("look") === true, "the draft");
  await act(async () => composer.current!.wake({ attachments: [image] }));
  await until(() => Boolean(field().querySelector("[data-inline-attachment] img")), "the kept image in the text");
  expect(field().textContent).not.toContain(MARK);
  expect(field().textContent).not.toContain(image.id);
});

// Review of #26545: after a send cleared the prompt, its Undo brought back the sent attachments'
// tokens (U+FFFC, the id, U+FFFC) with no attachment to draw, and the next send sent them as raw
// text. They went with the first prompt: an undo of the clear brings back the words, and a resend
// (in the undo's own task too) sends the words with no token and no attachment.
test("sending, undoing the clear, and resending never sends a sent attachment's token", async () => {
  const { inlineToken } = await import("../src/agent-session/acpmux/attachments");
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent);
  const image: ComposerAttachment = {
    id: "sent-then-undone",
    kind: "image",
    name: "image.png",
    mimeType: "image/png",
    size: PNG.length,
    data: pngBase64,
  };
  await act(async () => composer.current!.restore(`before ${inlineToken(image.id)} after`, [image]));
  await until(() => Boolean(field().querySelector("[data-inline-attachment] img")), "restored inline image");
  // A person sends a moment after writing: the field's history keeps the clear as its own step
  // (prosemirror-history joins steps less than 500 ms apart, by each transaction's Date.now()). The
  // clock moves past that gap instead of the test sleeping through it.
  const now = Date.now;
  Date.now = () => now() + 600;
  try {
    await act(async () => composer.current!.send());
    expect(sent).toHaveLength(1);
    expect(sent[0]!.attachments.map((attachment) => attachment.id)).toEqual([image.id]);
    await until(() => !field().textContent?.includes("before"), "the cleared prompt");
    // Undo, and a send in the same task, before anything after the undo ran.
    await act(async () => {
      markdownField().undo();
      composer.current!.send();
    });
    await until(() => field().textContent?.includes("before") === true, "the undone clear");
    for (let turn = 0; turn < 5; turn++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(field().querySelector("[data-inline-attachment]")).toBeNull();
    expect(field().textContent).not.toContain(MARK);
    expect(markdownField().value()).not.toContain(MARK);
    expect(composer.current!.wakeState().attachments ?? []).toEqual([]);
    if (sent.length === 1) await act(async () => composer.current!.send());
    expect(sent).toHaveLength(2);
    const resent = sent[1]!;
    expect(resent.attachments).toEqual([]);
    expect(resent.text).toContain("before");
    expect(resent.text).toContain("after");
    expect(resent.text).not.toContain(MARK);
    expect(resent.text).not.toContain(image.id);
    expect(JSON.stringify(promptBlocks(resent.text, resent.attachments))).not.toContain(image.id);
  } finally {
    Date.now = now;
  }
});

// Review of #26545: a failed attachment's Retry read its file again as a new paste under a new id,
// so the failed tile's node left the text and the retried attachment went in at the caret wherever
// it was by then. The retried attachment is the same one, where it was pasted, and goes with the
// prompt there.
test("a retried attachment keeps its id and its place in the text, wherever the caret is", async () => {
  let uploads = 0;
  // The host refuses the first upload outright (so its tile shows Retry at once, with no try again
  // on its own) and takes the Retry.
  const upload = async (files: File[]) => {
    uploads += 1;
    return uploads === 1
      ? { error: "The disk is full.", final: true }
      : { paths: files.map((file) => `/tmp/${file.name}`) };
  };
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent, { upload });
  await act(async () => composer.current!.restore("before after", []));
  await until(() => field().textContent?.includes("before after") === true, "the prompt");
  await act(async () => markdownField().setCaret("before ".length));
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  const archive = new File([new Uint8Array(64)], "notes.bin", { type: "application/octet-stream" });
  Object.defineProperty(event, "clipboardData", {
    value: { files: [archive], types: ["Files"], getData: () => "" },
  });
  await act(async () => {
    field().dispatchEvent(event);
  });
  const retry = () => field().querySelector<HTMLElement>('[data-state="failed"] .acpmux-md-inline-retry');
  await until(() => Boolean(retry()), "the failed tile");
  const original = field().querySelector("[data-inline-attachment]")!.getAttribute("data-inline-attachment")!;
  const placedAt = markdownField().value();
  expect(placedAt.indexOf("before")).toBeLessThan(placedAt.indexOf(MARK));
  expect(placedAt.indexOf(MARK)).toBeLessThan(placedAt.indexOf("after"));
  // The caret moves on before the Retry.
  await act(async () => markdownField().setCaret(Number.MAX_SAFE_INTEGER));
  await act(async () => {
    retry()!.click();
  });
  await until(() => (composer.current!.wakeState().attachments ?? []).length === 1, "the retried attachment");
  await until(() => Boolean(field().querySelector('[data-inline-attachment] [data-state="ready"]')), "its chip");
  expect(uploads).toBe(2);
  const [attachment] = composer.current!.wakeState().attachments!;
  expect(attachment!.id).toBe(original);
  expect(attachment!.path).toBe("/tmp/notes.bin");
  const nodes = [...field().querySelectorAll("[data-inline-attachment]")].map((node) =>
    node.getAttribute("data-inline-attachment"),
  );
  expect(nodes).toEqual([original]);
  expect(markdownField().value()).toBe(placedAt);
  await act(async () => composer.current!.send());
  expect(sent).toHaveLength(1);
  expect(sent[0]!.text).toBe(placedAt);
  expect(sent[0]!.attachments.map((each) => [each.id, each.path])).toEqual([[original, "/tmp/notes.bin"]]);
  const blocks = promptBlocks(sent[0]!.text, sent[0]!.attachments);
  expect(blocks[0]).toEqual({ type: "text", text: "before " });
  // Pasted at "before |after": nothing between the attachment and "after".
  expect(blocks.at(-1)).toEqual({ type: "text", text: "after" });
});

// 2df2917eec9 kept every sent attachment out of the text for good, so a prompt the host put back after
// its send (a refusal, Edit on a failed prompt) lost its attachments: the same ids come back, and
// they are the composer's again.
test("a prompt put back after its send keeps its inline attachment, and sends it again", async () => {
  const { inlineToken } = await import("../src/agent-session/acpmux/attachments");
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent);
  const image: ComposerAttachment = {
    id: "put-back",
    kind: "image",
    name: "image.png",
    mimeType: "image/png",
    size: PNG.length,
    data: pngBase64,
  };
  const prompt = `before ${inlineToken(image.id)} after`;
  await act(async () => composer.current!.restore(prompt, [image]));
  await until(() => Boolean(field().querySelector("[data-inline-attachment] img")), "restored inline image");
  await act(async () => composer.current!.send());
  expect(sent).toHaveLength(1);
  // The host refused it: the composer gets the prompt back, then the person types on.
  await act(async () => composer.current!.restore(sent[0]!.text, sent[0]!.attachments));
  await act(async () => markdownField().setCaret(Number.MAX_SAFE_INTEGER));
  await act(async () => markdownField().insertTyped("!"));
  for (let turn = 0; turn < 5; turn++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(field().querySelector("[data-inline-attachment] img")).not.toBeNull();
  expect((composer.current!.wakeState().attachments ?? []).map((attachment) => attachment.id)).toEqual([image.id]);
  await act(async () => composer.current!.send());
  expect(sent).toHaveLength(2);
  expect(sent[1]!.text).toBe(`${prompt}!`);
  expect(sent[1]!.attachments.map((attachment) => attachment.id)).toEqual([image.id]);
});

// Review of #26545 at 6c074193: only a command goes first with its attachments after it. A prompt
// that only starts with "/" (a path) keeps its image where it was put.
test.each([
  ["/tmp", true],
  ["/plan", false],
] as const)("a prompt starting %s keeps its inline image in place: %p", async (head, keeps) => {
  const { inlineToken } = await import("../src/agent-session/acpmux/attachments");
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent);
  const image: ComposerAttachment = {
    id: `slash-${keeps}`,
    kind: "image",
    name: "image.png",
    mimeType: "image/png",
    size: PNG.length,
    data: pngBase64,
  };
  await act(async () => composer.current!.restore(`${head} ${inlineToken(image.id)} exists`, [image]));
  await until(() => Boolean(field().querySelector("[data-inline-attachment] img")), "restored inline image");
  await act(async () => composer.current!.send());
  expect(sent).toHaveLength(1);
  const blocks = promptBlocks(sent[0]!.text, sent[0]!.attachments);
  if (keeps) {
    // The words around the image, the image between them.
    expect(blocks.map((block) => block.type)).toEqual(["text", "image", "text"]);
    expect(blocks[0]).toEqual({ type: "text", text: `${head} ` });
    expect(blocks[2]).toEqual({ type: "text", text: " exists" });
  } else {
    // A command: its words first, whole, the image after them.
    expect(blocks.map((block) => block.type)).toEqual(["text", "image"]);
    expect((blocks[0] as { text: string }).text.replace(/\s+/g, " ")).toBe(`${head} exists`);
  }
});

// Review of #26545 at 81dbee21: a failed upload stays reachable with Retry and ×. Since #30572 a send
// never goes without a file the person added (Leo, 2026-11-01: "i had to retry to get it to load???"):
// it waits while the failed tile shows, and goes once the × takes it away.
test("a send with a failed attachment waits until its x takes it away", async () => {
  const upload = async () => ({ error: "The disk is full.", final: true });
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent, { upload });
  await act(async () => composer.current!.restore("look", []));
  await until(() => field().textContent?.includes("look") === true, "the prompt");
  await act(async () => markdownField().setCaret("look".length));
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: {
      files: [new File([new Uint8Array(64)], "notes.bin", { type: "application/octet-stream" })],
      types: ["Files"],
      getData: () => "",
    },
  });
  await act(async () => {
    field().dispatchEvent(event);
  });
  const failed = () => field().querySelector('[data-state="failed"]');
  await until(() => Boolean(failed()), "the failed tile in the text");
  await act(async () => composer.current!.send());
  await settleTurns();
  expect(sent).toHaveLength(0);
  // Still reachable: its Retry and its ×.
  expect(failed()!.querySelector(".acpmux-md-inline-retry")).not.toBeNull();
  const remove = field().querySelector<HTMLElement>("[data-inline-attachment] .acpmux-md-inline-remove");
  expect(remove).not.toBeNull();
  await act(async () => {
    remove!.click();
  });
  await until(() => sent.length === 1, "the held send");
  expect(sent[0]!.text).toContain("look");
  expect(sent[0]!.attachments).toEqual([]);
});

// Review of #26667 (Astra), finding 1: the composer read the draft's tokens from its markdown, where
// text typed or pasted in the shape of a placed attachment's token (U+FFFC, its id, U+FFFC) reads
// the same as the editor's own node of it. That text then took the attachment's place: the prompt
// sent the pasted marker as the attachment, and once the node itself was deleted the attachment
// stayed with no chip drawn anywhere. Only the editor's own nodes are attachments; the rest is text.
const WORD_JOINER = "⁠";
const blockTexts = (sent: { text: string; attachments: ComposerAttachment[] }) =>
  promptBlocks(sent.text, sent.attachments).map((block) =>
    block.type === "text" ? `text:${block.text.replaceAll(WORD_JOINER, "")}` : block.type,
  );

async function withPlacedImage(id: string) {
  const { inlineToken } = await import("../src/agent-session/acpmux/attachments");
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent);
  const image: ComposerAttachment = {
    id,
    kind: "image",
    name: "image.png",
    mimeType: "image/png",
    size: PNG.length,
    data: pngBase64,
  };
  await act(async () => composer.current!.restore(`see ${inlineToken(image.id)} here`, [image]));
  await until(() => Boolean(field().querySelector("[data-inline-attachment] img")), "restored inline image");
  return { composer, sent, image, token: inlineToken(image.id) };
}
const settleTurns = async () => {
  for (let turn = 0; turn < 5; turn++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
};

test("text pasted with a placed attachment's token in it stays text, and the attachment keeps its place", async () => {
  const { composer, sent, image, token } = await withPlacedImage("pasted-marker");
  await act(async () => markdownField().setCaret(0));
  await act(async () => markdownField().pasteText(`look ${token} `));
  await settleTurns();
  const nodes = [...field().querySelectorAll("[data-inline-attachment]")].map((node) =>
    node.getAttribute("data-inline-attachment"),
  );
  expect(nodes).toEqual([image.id]);
  expect(field().querySelectorAll("[data-inline-attachment] img")).toHaveLength(1);
  await act(async () => composer.current!.send());
  expect(sent).toHaveLength(1);
  expect(sent[0]!.attachments.map((attachment) => attachment.id)).toEqual([image.id]);
  // The image goes where its chip is, between "see" and "here"; the pasted marker goes as the text it was.
  expect(blockTexts(sent[0]!)).toEqual([`text:look ${token} see `, "image", "text: here"]);
});

test("text typed with a placed attachment's token in it after the attachment goes as text", async () => {
  const { composer, sent, image, token } = await withPlacedImage("typed-marker");
  await act(async () => markdownField().setCaret(Number.MAX_SAFE_INTEGER));
  await act(async () => markdownField().insertTyped(` ${token}`));
  await settleTurns();
  expect(field().querySelectorAll("[data-inline-attachment] img")).toHaveLength(1);
  await act(async () => composer.current!.send());
  expect(sent[0]!.attachments.map((attachment) => attachment.id)).toEqual([image.id]);
  expect(blockTexts(sent[0]!)).toEqual(["text:see ", "image", `text: here ${token}`]);
});

test("deleting a placed attachment with its token pasted as text beside it takes the attachment out", async () => {
  const { composer, sent, image, token } = await withPlacedImage("deleted-beside-marker");
  await act(async () => markdownField().setCaret(0));
  await act(async () => markdownField().pasteText(`${token} `));
  await settleTurns();
  // The person deletes the attachment's own chip.
  await act(async () => markdownField().removeInline(image.id));
  await settleTurns();
  expect(field().querySelector("[data-inline-attachment]")).toBeNull();
  // No attachment hides behind the pasted text: none is left, in the text or the strip.
  expect(composer.current!.wakeState().attachments ?? []).toEqual([]);
  await act(async () => composer.current!.send());
  expect(sent[0]!.attachments).toEqual([]);
  expect(blockTexts(sent[0]!)).toEqual([`text:${token} see  here`]);
});

// Review of #26667 (Astra), finding 2: a file still streaming to the session's machine does not
// hold a send; it stays for the next prompt (attachmentIntake.tsx useSendWhenAttached). The send's
// clear took its node out of the text as an edit, and the edit cancelled it: its upload was dropped
// and the next prompt went without it. A node the person deletes is still cancelled.
async function withUploadingFile(onSend?: ComposerProps["onSend"]) {
  let finish: ((paths: string[]) => void) | undefined;
  const upload = () =>
    new Promise<{ paths: string[] }>((resolve) => {
      finish = (paths) => resolve({ paths });
    });
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent, { upload, ...(onSend ? { onSend } : {}) });
  await act(async () => composer.current!.restore("see", []));
  await act(async () => markdownField().setCaret(Number.MAX_SAFE_INTEGER));
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  const archive = new File([new Uint8Array(64)], "notes.bin", { type: "application/octet-stream" });
  Object.defineProperty(event, "clipboardData", {
    value: { files: [archive], types: ["Files"], getData: () => "" },
  });
  await act(async () => {
    field().dispatchEvent(event);
  });
  await until(
    () => finish !== undefined && Boolean(field().querySelector("[data-inline-attachment]")),
    "the uploading placeholder in the text",
  );
  const id = field().querySelector("[data-inline-attachment]")!.getAttribute("data-inline-attachment")!;
  return { composer, sent, id, finish: (paths: string[]) => act(async () => finish!(paths)) };
}

// Before #30572 a prompt sent while its file uploaded went without it (Leo, 2026-11-01: the agent
// answered "Nothing came through"); the send now waits for the upload and goes once, with the file.
test("a prompt sent while its file still uploads waits for it, then goes once with it", async () => {
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const upload = await withUploadingFile(async (text, attachments) => {
    sent.push({ text, attachments: attachments ?? [] });
  });
  await act(async () => upload.composer.current!.send());
  await settleTurns();
  expect(sent).toHaveLength(0);
  await upload.finish(["/tmp/notes.bin"]);
  await until(() => sent.length === 1, "the held send");
  expect(sent[0]!.attachments.map((each) => [each.id, each.path])).toEqual([[upload.id, "/tmp/notes.bin"]]);
});

test("a file still uploading whose node the person deletes is cancelled", async () => {
  const upload = await withUploadingFile();
  await act(async () => markdownField().removeInline(upload.id));
  await settleTurns();
  await upload.finish(["/tmp/notes.bin"]);
  await settleTurns();
  expect(upload.composer.current!.wakeState().attachments ?? []).toEqual([]);
  expect(field().querySelector("[data-inline-attachment]")).toBeNull();
  expect(host.querySelector('[aria-busy="true"]')).toBeNull();
});

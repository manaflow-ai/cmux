// Leo 2026-10-20: two images copied in Chrome and pasted into the composer showed as chips and also
// full size in the field, as `![Screenshot · 778×696](data:image/png;base64,…)`; the prompt went out
// with that text, the bubble showed pages of base64 and the chat's compaction failed. A pasted image
// is an attachment chip only: the field gets nothing but plain text, a prompt's text never carries a
// `data:` URI (it goes as an ACP image block), and a bubble never draws one.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, type RefObject } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { promptBlocks, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { liftInlineImages, withoutDataUris } from "../src/agent-session/acpmux/inlineImages";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

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

async function openComposer(sent: { text: string; attachments: ComposerAttachment[] }[] = []) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const handle = createRef<ComposerHandle>();
  opened = handle;
  const snapshot = noChat([], {
    sessionId: "chat-a",
    summary: { sessionId: "chat-a", harness: "codex", cwd: "/Users/you/src/app", turnCount: 0 },
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
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
      />,
    ),
  );
  return handle;
}

const field = () => host.querySelector<HTMLElement>('[role="combobox"]')!;

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

test("pasting two copied images makes two chips and puts nothing in the prompt", async () => {
  const composer = await openComposer();
  await paste({ files: [screenshot(1), screenshot(2)], html: imageHtml(2) });
  const chips = composer.current!.wakeState().attachments ?? [];
  expect(chips.map((chip) => chip.kind)).toEqual(["image", "image"]);
  expect(chips.every((chip) => chip.data === pngBase64)).toBe(true);
  // Nothing inline: no image drawn in the field and no markup or base64 in its text.
  expect(field().querySelector("img")).toBeNull();
  expect(field().textContent).toBe("");
  expect(field().innerHTML).not.toContain("data:");
});

test("an image copied as HTML alone (no file on the clipboard) still comes in as a chip, its text as text", async () => {
  const composer = await openComposer();
  await paste({ html: `<p>look at these</p>${imageHtml(2)}`, plain: "look at these" });
  expect((composer.current!.wakeState().attachments ?? []).map((chip) => chip.kind)).toEqual(["image", "image"]);
  expect(field().querySelector("img")).toBeNull();
  expect(field().textContent).toBe("look at these");
  expect(field().innerHTML).not.toContain("data:");
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
  const selection = { id: "card-1", name: "Card", text: "hello", image: { mimeType: "image/png", data: "AA==" } };
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
    Object.defineProperty(file, "arrayBuffer", { value: () => Promise.reject(new Error("folder")) });
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

test("an image copied as HTML into a plain text field comes in as a chip and the text still goes in", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useAttachmentIntake } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  let held: ComposerAttachment[] = [];
  function Field() {
    const { attachments } = useAttachmentIntake({ allowImages: true, pasteTarget: () => ({ uploads: false }) });
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

test("a prompt copied from a bubble with `![…](data:…)` text pastes as a chip and its text, nothing inline", async () => {
  const composer = await openComposer();
  await paste({ plain: `![Screenshot · 778×696](${dataUri} "Screenshot · 778×696")what the heck` });
  expect((composer.current!.wakeState().attachments ?? []).map((chip) => chip.kind)).toEqual(["image"]);
  expect(field().querySelector("img")).toBeNull();
  expect(field().textContent).toBe("what the heck");
  expect(field().innerHTML).not.toContain("data:");
});

test("the same text pasted into a plain text field leaves its text there without the image", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useAttachmentIntake } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  let held: ComposerAttachment[] = [];
  function Field() {
    const { attachments } = useAttachmentIntake({ allowImages: true, pasteTarget: () => ({ uploads: false }) });
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

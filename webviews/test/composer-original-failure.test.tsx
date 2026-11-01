// l10n-allow-file: synthetic file names and host errors for a behavioral regression.
// An image is its chip once its preview is made, while its original still uploads (composer/
// intakeFiles.ts). When that upload fails, the chip says so and offers Retry, and the preview
// still sends; when the person sends or removes the chip, the cancelled upload stays silent.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useImperativeHandle, type Ref } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { promptBlocks, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { UploadResult } from "../src/agent-session/acpmux/cloudUploads";
import {
  AttachmentStrip,
  useAttachmentIntake,
  type AttachmentIntakeOptions,
} from "../src/agent-session/acpmux/composer/attachmentIntake";
import { intakeFiles, type IntakeEvents } from "../src/agent-session/acpmux/composer/intakeFiles";

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
        return new Blob(["pixels"], { type });
      }
    },
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

const png = (name: string) => new File(["png"], name, { type: "image/png" });

/// What intake reported, in order.
function recorder() {
  const events: string[] = [];
  const handlers: IntakeEvents = {
    ready: (index, chip) => events.push(`ready ${index} ${chip.kind}`),
    failed: (index) => events.push(`failed ${index}`),
    original: (index, path) => events.push(`original ${index} ${path}`),
    originalFailed: (index, error) =>
      events.push(`originalFailed ${index} ${"text" in error ? error.text : error.reason}`),
  };
  return { events, handlers };
}

test("an image whose original's upload fails is reported, after its preview, never as a failed chip", async () => {
  const { events, handlers } = recorder();
  const taken = await intakeFiles(
    [png("shot.png")],
    { allowImages: true, upload: async (): Promise<UploadResult> => ({ error: "The disk is full." }) },
    handlers,
  );
  expect(events).toEqual(["ready 0 image", "originalFailed 0 The disk is full."]);
  expect(taken.attachments).toHaveLength(1);
});

test("an upload that throws or answers no path fails the original too", async () => {
  for (const upload of [
    async (): Promise<UploadResult> => {
      throw new Error("The connection closed.");
    },
    async (): Promise<UploadResult> => undefined,
  ]) {
    const { events, handlers } = recorder();
    await intakeFiles([png("shot.png")], { allowImages: true, upload }, handlers);
    expect(events[0]).toBe("ready 0 image");
    expect(events[1]?.startsWith("originalFailed 0")).toBe(true);
  }
});

test("a cancelled original (its chip sent or removed) stays silent, and a saved one is no failure", async () => {
  const cancelled = recorder();
  await intakeFiles(
    [png("shot.png")],
    { allowImages: true, cancelled: () => true, upload: async () => ({ error: "cancelled" }) },
    cancelled.handlers,
  );
  expect(cancelled.events).toEqual(["ready 0 image"]);
  // The upload's own cancellation: the file was taken away while it went, so its path is "".
  let taken = false;
  const midway = recorder();
  await intakeFiles(
    [png("shot.png")],
    {
      allowImages: true,
      cancelled: () => taken,
      upload: async () => {
        taken = true;
        return { paths: [""] };
      },
    },
    midway.handlers,
  );
  expect(midway.events).toEqual(["ready 0 image"]);
  const ok = recorder();
  await intakeFiles(
    [png("shot.png")],
    { allowImages: true, upload: async () => ({ paths: ["/tmp/shot.png"] }) },
    ok.handlers,
  );
  expect(ok.events).toEqual(["ready 0 image", "original 0 /tmp/shot.png"]);
});

test("a staged image whose original failed shows Retry beside its preview", () => {
  const chip: ComposerAttachment = {
    id: "shot",
    kind: "image",
    name: "shot.png",
    mimeType: "image/png",
    size: 3,
    data: btoa("pixels"),
  };
  const failures = { shot: "The disk is full." };
  const html = renderToStaticMarkup(
    <AttachmentStrip attachments={[chip]} onRemove={() => {}} onRetry={() => {}} originalFailures={failures} />,
  );
  expect(html).toContain("<img");
  expect(html).toContain('class="acpmux-attachment-original-retry"');
  expect(html).toContain("The disk is full.");
  // Without a Retry to offer, or without this page's failure (a draft, a wake or another chat brought
  // the chip back), the preview shows as it did.
  const noRetry = renderToStaticMarkup(
    <AttachmentStrip attachments={[chip]} onRemove={() => {}} originalFailures={failures} />,
  );
  const noFailure = renderToStaticMarkup(
    <AttachmentStrip attachments={[chip]} onRemove={() => {}} onRetry={() => {}} />,
  );
  expect(noRetry).not.toContain("acpmux-attachment-original-retry");
  expect(noFailure).not.toContain("acpmux-attachment-original-retry");
});

// Leo, 2026-10-31: "video attachments (big attachments?) still sucks", over a strip of empty tiles
// that each showed only an underlined "Retry". A failed tile keeps its shape and kind and shows one
// small retry glyph button (why is in its tooltip); a streaming one shows how far it got.
test("a failed tile shows its kind and one retry glyph button; a streaming one shows its progress", () => {
  const html = renderToStaticMarkup(
    <AttachmentStrip
      attachments={[]}
      pending={[
        { id: "video", name: "Screen Recording.mov", image: false, failed: "The upload timed out." },
        { id: "shot", name: "shot.png", image: true, failed: "The disk is full." },
        { id: "big", name: "big.mp4", image: false, uploading: true, progress: 0.42 },
      ]}
      onRemove={() => {}}
      onCancel={() => {}}
      onRetry={() => {}}
    />,
  );
  // The file's name stays on its tile; each failed tile has exactly one retry button, a glyph.
  expect(html).toContain("Screen Recording.mov");
  expect(html.match(/class="acpmux-attachment-retry"/g)?.length).toBe(2);
  expect(html).not.toMatch(/class="acpmux-attachment-retry"[^>]*>Retry</);
  expect(html).toContain('title="The upload timed out."');
  expect(html).toMatch(/<progress[^>]*value="42"/);
});

type Intake = ReturnType<typeof useAttachmentIntake>;
function Harness({ options, handle }: { options: AttachmentIntakeOptions; handle: Ref<Intake> }) {
  const intake = useAttachmentIntake(options);
  useImperativeHandle(handle, () => intake);
  return (
    <AttachmentStrip
      attachments={intake.attachments}
      pending={intake.pending}
      onRemove={() => {}}
      onRetry={intake.retry}
      originalFailures={intake.originalFailures}
    />
  );
}

/// Resolves once `check` holds after a render (each state change re-renders the harness).
async function until(check: () => boolean) {
  for (let turn = 0; turn < 200 && !check(); turn++) await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(check()).toBe(true);
}

test("Retry on a staged image uploads its original again; the preview sends meanwhile", async () => {
  const answers: UploadResult[] = [{ error: "The disk is full." }, { paths: ["/remote/shot.png"] }];
  const uploaded: string[][] = [];
  const options: AttachmentIntakeOptions = {
    allowImages: true,
    pasteTarget: () => undefined,
    upload: async (files) => {
      uploaded.push(files.map((file) => file.name));
      return answers.shift();
    },
  };
  const handle: { current: Intake | null } = { current: null };
  root = createRoot(host);
  act(() => root!.render(<Harness options={options} handle={handle} />));
  await act(() => handle.current!.attach([png("shot.png")], true));
  await until(() => Boolean(handle.current!.originalFailures[handle.current!.attachments[0]?.id ?? ""]));
  const chip = handle.current!.attachments[0]!;
  expect(handle.current!.originalFailures).toEqual({ [chip.id]: "The disk is full." });
  // The chip itself carries nothing of it: a draft or a wake takes the preview without a dead Retry.
  expect(chip).not.toHaveProperty("originalFailed");
  expect(handle.current!.pending).toEqual([]);
  // The preview still goes as an image block, without its original.
  expect(promptBlocks("", [chip]).map((block) => block.type)).toEqual(["image"]);
  const retry = host.querySelector<HTMLButtonElement>(".acpmux-attachment-original-retry");
  expect(retry).not.toBeNull();
  act(() => retry!.click());
  await until(() => handle.current!.attachments[0]?.originalPath === "/remote/shot.png");
  expect(handle.current!.originalFailures).toEqual({});
  expect(uploaded).toEqual([["shot.png"], ["shot.png"]]);
  expect(host.querySelector(".acpmux-attachment-original-retry")).toBeNull();
});

// Review (Astra): Retry's upload stops once its chip leaves the strip, also after the chip moved
// with the composer to another chat, and a chip out of the strip keeps no file for a Retry it
// cannot show, also when it left with a switch to another chat.
test("Retry's upload stops when its carried chip leaves the strip", async () => {
  const uploaded: string[][] = [];
  let retrying: ((index: number) => boolean) | undefined;
  let finish = () => {};
  const upload: AttachmentIntakeOptions["upload"] = async (files, cancelled) => {
    uploaded.push(files.map((file) => file.name));
    if (uploaded.length === 1) return { error: "The disk is full." };
    retrying = cancelled;
    await new Promise<void>((resolve) => (finish = resolve));
    return { error: "cancelled" };
  };
  const options = (scope: string): AttachmentIntakeOptions => ({
    allowImages: true,
    pasteTarget: () => undefined,
    upload,
    scope,
    carries: () => true,
  });
  const handle: { current: Intake | null } = { current: null };
  root = createRoot(host);
  act(() => root!.render(<Harness options={options("A")} handle={handle} />));
  await act(() => handle.current!.attach([png("shot.png")], true));
  await until(() => Boolean(handle.current!.originalFailures[handle.current!.attachments[0]?.id ?? ""]));
  // A harness switch: the composer, its strip with this chip, moves to the new chat.
  act(() => root!.render(<Harness options={options("B")} handle={handle} />));
  act(() => host.querySelector<HTMLButtonElement>(".acpmux-attachment-original-retry")!.click());
  await until(() => retrying !== undefined);
  expect(retrying!(0)).toBe(false);
  act(() => handle.current!.setAttachments([]));
  expect(retrying!(0)).toBe(true);
  await act(async () => finish());
  expect(handle.current!.attachments).toEqual([]);
});

test("a failed original whose chip left with a switch to another chat keeps no file for Retry", async () => {
  const uploaded: string[][] = [];
  const options = (scope: string): AttachmentIntakeOptions => ({
    allowImages: true,
    pasteTarget: () => undefined,
    scope,
    upload: async (files) => {
      uploaded.push(files.map((file) => file.name));
      return { error: "The disk is full." };
    },
  });
  const handle: { current: Intake | null } = { current: null };
  root = createRoot(host);
  act(() => root!.render(<Harness options={options("A")} handle={handle} />));
  await act(() => handle.current!.attach([png("shot.png")], true));
  await until(() => Boolean(handle.current!.originalFailures[handle.current!.attachments[0]?.id ?? ""]));
  const chip = handle.current!.attachments[0]!;
  // Another chat shows: its strip has its own chips (the composer's kept drafts swap them).
  act(() => root!.render(<Harness options={options("B")} handle={handle} />));
  act(() => handle.current!.setAttachments([]));
  // The file went when the chip left: the same chip staged again (here, while B shows) runs no Retry
  // for a file no longer held.
  act(() => handle.current!.setAttachments([chip]));
  act(() => handle.current!.retry(chip.id));
  expect(uploaded).toEqual([["shot.png"]]);
});

// Review (Astra) at fb51546b asked whether a carried chip's Retry should survive the switch. It
// should: a chip is carried only when the prompt moves to the new chat (a harness switch), so the
// original belongs on the new chat's machine and Retry uploads it there. A switch that does not
// carry swaps the strip for the other chat's chips, and the failure goes with the chip (above).
test("a carried chip's Retry uploads its original to the chat the prompt moved to", async () => {
  const uploads: string[] = [];
  const options = (scope: string): AttachmentIntakeOptions => ({
    allowImages: true,
    pasteTarget: () => undefined,
    scope,
    carries: () => true,
    upload: async () => {
      uploads.push(scope);
      return scope === "A" ? { error: "The disk is full." } : { paths: [`/${scope}/shot.png`] };
    },
  });
  const handle: { current: Intake | null } = { current: null };
  root = createRoot(host);
  act(() => root!.render(<Harness options={options("A")} handle={handle} />));
  await act(() => handle.current!.attach([png("shot.png")], true));
  await until(() => Boolean(handle.current!.originalFailures[handle.current!.attachments[0]?.id ?? ""]));
  act(() => root!.render(<Harness options={options("B")} handle={handle} />));
  act(() => host.querySelector<HTMLButtonElement>(".acpmux-attachment-original-retry")!.click());
  await until(() => handle.current!.attachments[0]?.originalPath === "/B/shot.png");
  expect(uploads).toEqual(["A", "B"]);
  expect(handle.current!.originalFailures).toEqual({});
});

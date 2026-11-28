// l10n-allow-file: synthetic file names and host errors for a behavioral regression.
// An image is its chip once its preview is made, while its original still uploads (composer/
// intakeFiles.ts). When that upload fails it is asked again on its own, with no Retry (Leo,
// 2026-11-22: "vacuous decisions like that should be just done"; composer/uploadRetry.ts); a failure
// that lasts gets one quiet mark on the chip, and the preview still sends; when the person sends or
// removes the chip, the cancelled upload stays silent.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useImperativeHandle, type Ref } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { UploadResult } from "../src/agent-session/acpmux/cloudUploads";
import type { AttachmentIntakeOptions } from "../src/agent-session/acpmux/composer/attachmentIntakeModel";
import type { IntakeEvents } from "../src/agent-session/acpmux/composer/intakeFiles";
import { LASTING_MS, setLastingGrace } from "../src/ui/lasting";
import { teardownDom } from "./support/domTeardown";
import { importWithDom } from "./support/importWithDom";

const { promptBlocks } = await importWithDom(() => import("../src/agent-session/acpmux/attachments"));
const { AttachmentStrip } = await importWithDom(() => import("../src/agent-session/acpmux/composer/attachmentIntake"));
const { useAttachmentIntake } = await importWithDom(
  () => import("../src/agent-session/acpmux/composer/attachmentIntakeModel"),
);
const { intakeFiles } = await importWithDom(() => import("../src/agent-session/acpmux/composer/intakeFiles"));

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

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
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

test("a staged image whose original keeps failing shows one quiet mark beside its preview, never a button", () => {
  const chip: ComposerAttachment = {
    id: "shot",
    kind: "image",
    name: "shot.png",
    mimeType: "image/png",
    size: 3,
    data: btoa("pixels"),
  };
  const failures = { shot: "The disk is full." };
  // The failure has lasted the house deadline (lasting.ts; 0 here, as in the gallery's frames).
  setLastingGrace(0);
  let html: string;
  try {
    html = renderToStaticMarkup(
      <AttachmentStrip attachments={[chip]} onRemove={() => {}} originalFailures={failures} />,
    );
  } finally {
    setLastingGrace(LASTING_MS);
  }
  expect(html).toContain("<img");
  expect(html).toContain('class="acpmux-attachment-original-still"');
  expect(html).toContain("The disk is full.");
  expect(html).not.toContain("acpmux-attachment-original-retry");
  // Only the chip's x is a button.
  expect(html.match(/<button/g)?.length).toBe(1);
  // Before the deadline it says nothing (it is being asked again), and without this page's failure
  // (a draft, a wake or another chat brought the chip back) the preview shows as it did.
  const early = renderToStaticMarkup(
    <AttachmentStrip attachments={[chip]} onRemove={() => {}} originalFailures={failures} />,
  );
  const noFailure = renderToStaticMarkup(<AttachmentStrip attachments={[chip]} onRemove={() => {}} />);
  expect(early).not.toContain("acpmux-attachment-original-still");
  expect(noFailure).not.toContain("acpmux-attachment-original-still");
});

// Leo, 2026-10-31: "video attachments (big attachments?) still sucks", over a strip of empty tiles
// that each showed only an underlined "Retry". A tile whose upload is asked again keeps its shape and
// kind and keeps loading (once that lasts, its tooltip says it still tries, and why); a refused one
// shows only its x; a streaming one shows how far it got.
test("a tile still asked again keeps loading with its reason; a refused one has only its x; a streaming one shows its progress", () => {
  setLastingGrace(0);
  let html: string;
  try {
    html = renderToStaticMarkup(
      <AttachmentStrip
        attachments={[]}
        pending={[
          { id: "video", name: "Screen Recording.mov", image: false, retrying: "The upload timed out." },
          { id: "shot", name: "shot.png", image: true, retrying: "The disk is full." },
          // A file the composer refused fails the same way again: never asked again, only its x.
          { id: "refused", name: "notes.heic", image: true, failed: "notes.heic can't be attached" },
          { id: "big", name: "big.mp4", image: false, uploading: true, progress: 0.42 },
        ]}
        onRemove={() => {}}
        onCancel={() => {}}
      />,
    );
  } finally {
    setLastingGrace(LASTING_MS);
  }
  expect(html).toContain("Screen Recording.mov");
  expect(html.match(/data-still-trying/g)?.length).toBe(2);
  expect(html).toContain("The upload timed out.");
  expect(html).toContain("notes.heic can");
  expect(html).not.toContain("acpmux-attachment-retry");
  expect(html).not.toMatch(/>Retry</);
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
      originalFailures={intake.originalFailures}
    />
  );
}

/// Resolves once `check` holds, looked at again after each turn of the event loop (each state change
/// re-renders the harness), giving up after `within` ms: the asks again back off from 0.5-1 s, then 1-2 s (autoRetry.ts).
async function until(check: () => boolean, within = 4_000) {
  const end = Date.now() + within;
  while (!check() && Date.now() < end) await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(check()).toBe(true);
}

test("a staged image's original that failed is uploaded again on its own; the preview sends meanwhile", async () => {
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
  // The chip itself carries nothing of it: a draft or a wake takes the preview as it is.
  expect(chip).not.toHaveProperty("originalFailed");
  expect(handle.current!.pending).toEqual([]);
  // The preview still goes as an image block, without its original.
  expect(promptBlocks("", [chip]).map((block) => block.type)).toEqual(["image"]);
  // Nothing to click, and no mark before the failure lasts.
  expect(host.querySelector(".acpmux-attachment-original-retry")).toBeNull();
  expect(host.querySelector(".acpmux-attachment-original-still")).toBeNull();
  await until(() => handle.current!.attachments[0]?.originalPath === "/remote/shot.png");
  expect(handle.current!.originalFailures).toEqual({});
  expect(uploaded).toEqual([["shot.png"], ["shot.png"]]);
});

// Review (Astra) at 69987495, and Sol at 04641cba: in a chat on this Mac too the original is saved
// again (a prompt too large for one message goes with links to the originals only once they are
// saved); it keeps going while it fails and stops once saved.
test("a local chat saves the original again on its own until it is saved, and then asks no more", async () => {
  const answers: UploadResult[] = [
    { error: "The disk is full." },
    { error: "Still full." },
    { paths: ["/Users/me/Chat Uploads/shot.png"] },
  ];
  const uploads: string[][] = [];
  const options: AttachmentIntakeOptions = {
    allowImages: true,
    pasteTarget: () => undefined,
    localChat: true,
    upload: async (files) => {
      uploads.push(files.map((file) => file.name));
      return answers.shift() ?? { error: "asked after it was saved" };
    },
  };
  const handle: { current: Intake | null } = { current: null };
  root = createRoot(host);
  act(() => root!.render(<Harness options={options} handle={handle} />));
  await act(() => handle.current!.attach([png("shot.png")], true));
  await until(() => uploads.length === 2);
  await until(() => handle.current!.originalFailures[handle.current!.attachments[0]!.id] === "Still full.");
  await until(() => handle.current!.attachments[0]?.originalPath === "/Users/me/Chat Uploads/shot.png", 6_000);
  expect(handle.current!.originalFailures).toEqual({});
  // fixed-wait: past the next backoff step, to see that a saved original is not asked again.
  await act(() => new Promise((resolve) => setTimeout(resolve, 2_500)));
  expect(uploads).toEqual([["shot.png"], ["shot.png"], ["shot.png"]]);
});

// Review (Astra): an original's upload asked again stops once its chip leaves the strip, also after
// the chip moved with the composer to another chat.
test("an original asked again stops when its carried chip leaves the strip", async () => {
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
  await until(() => retrying !== undefined);
  expect(retrying!(0)).toBe(false);
  act(() => handle.current!.setAttachments([]));
  expect(retrying!(0)).toBe(true);
  await act(async () => finish());
  expect(handle.current!.attachments).toEqual([]);
  // fixed-wait: past the next backoff step: a chip that left is not asked again.
  await act(() => new Promise((resolve) => setTimeout(resolve, 2_500)));
  expect(uploaded).toEqual([["shot.png"], ["shot.png"]]);
});

test("a failed original whose chip left with a switch to another chat keeps no file to ask again", async () => {
  const uploaded: string[] = [];
  const options = (scope: string): AttachmentIntakeOptions => ({
    allowImages: true,
    pasteTarget: () => undefined,
    scope,
    upload: async () => {
      uploaded.push(scope);
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
  act(() => {
    root!.render(<Harness options={options("B")} handle={handle} />);
    handle.current!.setAttachments([]);
  });
  // The file went when the chip left: the same chip staged again (here, while B shows) is not
  // uploaded, on its own or asked at once, for a file no longer held, and nothing goes to B.
  act(() => handle.current!.setAttachments([chip]));
  act(() => handle.current!.retry(chip.id));
  // fixed-wait: past the first backoff steps.
  await act(() => new Promise((resolve) => setTimeout(resolve, 2_000)));
  expect(uploaded).toEqual(["A"]);
});

// Review (Astra) at fb51546b asked whether a carried chip's original should be saved again after the
// switch. It should: a chip is carried only when the prompt moves to the new chat (a harness switch),
// so the original belongs on the new chat's machine and is uploaded there. A switch that does not
// carry swaps the strip for the other chat's chips, and the failure goes with the chip (above).
test("a carried chip's original is uploaded again to the chat the prompt moved to", async () => {
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
  await until(() => handle.current!.attachments[0]?.originalPath === "/B/shot.png");
  expect(uploads).toEqual(["A", "B"]);
  expect(handle.current!.originalFailures).toEqual({});
});

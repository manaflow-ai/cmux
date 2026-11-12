// The DEBUG `debug.agent_pane paste_probe` verb (window.cmuxAcpmuxDebug.pasteProbe): pastes a
// Retina-sized screenshot into the composer through the page's own paste path and times what the
// person sees, then times the steps that path is made of, on this engine and with this host
// (https://github.com/manaflow-ai/cmux/issues/41016, "Cmd+V of an image is slow"). The pasteboard
// read itself is the engine's, before the paste event: a window that is never key cannot take a
// real Cmd-V, so it is not in these numbers.
import { instantPreview } from "./composer/attachmentIntakeModel";
import { prepareImageOffThread } from "./composer/imagePool";
import { callHost } from "./composer/attachmentSources";

export type PasteProbeOptions = {
  width?: number;
  height?: number;
  kind?: "text" | "noise";
  /// Then send the prompt (as Return does) and watch the transcript for `watchMs`: every frame in
  /// which an id (a UUID) shows as text the person can see is reported (issue 41016's second part).
  send?: boolean;
  watchMs?: number;
  /// Waits for the person's own paste (a real Cmd-V, `debug.key {target: "page"}`) instead of making
  /// one, so the engine's read of the pasteboard counts too: times from the key down.
  real?: boolean;
  /// With `real`: the next press in the page asks the host for the engine's own paste (`pane.edit
  /// paste`, the composer menu's Paste), timed from then: a window that is never key takes no Cmd-V.
  edit?: boolean;
  /// The last probe's result (or `{running: true}`), without starting one: a page call has only a
  /// few seconds to answer (CEF's DevTools evaluate), less than a probe takes.
  read?: boolean;
};

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

/// The text the person can see in the page that holds a UUID, each with its element's class.
function shownIds(): string[] {
  const found: string[] = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const text = node.textContent ?? "";
    const parent = node.parentElement;
    if (!parent || !UUID.test(text)) continue;
    if (parent.closest("script,style,[aria-hidden='true'],.visually-hidden,.acpmux-attachment-voiceover-only"))
      continue;
    const box = parent.getBoundingClientRect();
    if (box.width === 0 || box.height === 0) continue;
    found.push(
      `${parent.tagName.toLowerCase()}.${String(parent.className).split(" ").join(".")}: ${text.slice(0, 80)}`,
    );
  }
  // An image that has not drawn yet shows its alt text in its place.
  for (const image of document.querySelectorAll("img"))
    if (UUID.test(image.alt) && !(image.complete && image.naturalWidth)) found.push(`img alt: ${image.alt}`);
  return found;
}

/// Every frame for `ms` in which the page shows a UUID (`shownIds`), with its time.
function watchIds(ms: number): Promise<string[]> {
  return new Promise((resolve) => {
    const start = performance.now();
    const seen = new Map<string, number>();
    const frame = () => {
      for (const id of shownIds()) if (!seen.has(id)) seen.set(id, since(start));
      if (performance.now() - start < ms) requestAnimationFrame(frame);
      else resolve([...seen].map(([id, at]) => `${at} ms ${id}`));
    };
    requestAnimationFrame(frame);
  });
}

/// Milliseconds from the paste to each thing the composer shows, and how long each step took.
export type PasteProbeResult = Record<string, number | string | boolean | undefined>;

/// The chat's composer, or the New Tab page's, where a new chat's first prompt is written.
const PROMPT = ".acpmux-composer-prompt [contenteditable='true'], .ProseMirror.acpmux-md[contenteditable='true']";
const LOADING = '.acpmux-md-inline-chip[data-state="loading"], .acpmux-attachment-pending';
const READY_IMG =
  '.acpmux-md-inline-chip[data-state="ready"] img, .acpmux-attachment-image:not(.acpmux-attachment-pending) img';

/// A screenshot of a code editor (`text`) or of noise that compresses badly (`noise`), as a PNG.
async function screenshot({ width = 3456, height = 2234, kind = "text" }: PasteProbeOptions): Promise<File> {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d")!;
  context.fillStyle = "#1e1f24"; // colour-allow: a synthetic screenshot's pixels, never UI
  context.fillRect(0, 0, width, height);
  if (kind === "noise") {
    const band = context.getImageData(0, 0, width, Math.min(900, height));
    for (let at = 0; at < band.data.length; at += 4) {
      const value = (Math.random() * 255) | 0;
      band.data[at] = band.data[at + 1] = band.data[at + 2] = value;
      band.data[at + 3] = 255;
    }
    context.putImageData(band, 0, 0);
  } else {
    context.font = "26px Menlo, monospace";
    const colors = ["#d4d4d4", "#9cdcfe", "#ce9178", "#6a9955", "#c586c0"]; // colour-allow: a synthetic screenshot's pixels, never UI
    for (let y = 40, line = 0; y < height; y += 36, line += 1) {
      let text = "";
      while (text.length < 200) text += `${Math.random().toString(36).slice(2)} `;
      context.fillStyle = colors[line % colors.length]!;
      context.fillText(`${String(line).padStart(4)}  ${text}`, 20, y);
    }
  }
  const blob = await new Promise<Blob>((resolve, reject) =>
    canvas.toBlob((png) => (png ? resolve(png) : reject(new Error("no PNG"))), "image/png"),
  );
  // WebKit and Chromium name pasted image data so.
  return new File([blob], "image.png", { type: "image/png" });
}

const readyImages = () => [...document.querySelectorAll<HTMLImageElement>(READY_IMG)];

const since = (start: number) => Math.round(performance.now() - start);

async function timed<T>(work: () => Promise<T>): Promise<number> {
  const start = performance.now();
  await work().catch(() => undefined);
  return since(start);
}

/// The probe running or done last, which `read` answers.
let last: { running: true } | PasteProbeResult | undefined;
let running: Promise<PasteProbeResult> | undefined;

/// Starts a probe and answers at once (`{started: true}`); with `read`, answers the last one; with
/// `wait` (a test's page call, which has no deadline), answers the last one once it ends.
export async function pasteProbe(options: PasteProbeOptions & { wait?: boolean }): Promise<PasteProbeResult> {
  if (options.wait) return (await running) ?? last ?? { error: "no probe ran" };
  if (options.read) return last ?? { error: "no probe ran" };
  if (last && "running" in last) return { error: "a probe is running" };
  last = { running: true };
  running = runProbe(options).then(
    (result) => (last = result),
    (error: unknown) => (last = { error: String(error) }),
  );
  return { started: 1 };
}

async function runProbe(options: PasteProbeOptions): Promise<PasteProbeResult> {
  const prompt = document.querySelector<HTMLElement>(PROMPT);
  if (!prompt) return { error: "no composer prompt" };
  const file = options.real ? undefined : await screenshot(options);
  const result: PasteProbeResult = file ? { bytes: file.size } : {};
  const marks = await new Promise<Record<string, number>>((resolve) => {
    const found: Record<string, number> = {};
    let start = performance.now();
    // Chips and tiles from an earlier paste are not this one's.
    const before = { tiles: document.querySelectorAll(LOADING).length, ready: readyImages().length };
    let stall = 0;
    let beatAt = start;
    const beat = window.setInterval(() => {
      const now = performance.now();
      stall = Math.max(stall, now - beatAt);
      beatAt = now;
    }, 4);
    const deadline = window.setTimeout(() => finish(), 30_000);
    const finish = () => {
      window.clearInterval(beat);
      window.clearTimeout(deadline);
      resolve({ ...found, stall: Math.round(stall) });
    };
    const check = () => {
      const at = since(start);
      if (found.tile === undefined && document.querySelectorAll(LOADING).length > before.tiles) found.tile = at;
      const instant = document.querySelector<HTMLImageElement>(".acpmux-attachment-instant");
      if (found.instant === undefined && instant?.complete && instant.naturalWidth) found.instant = at;
      if (readyImages().filter((image) => image.complete && image.naturalWidth).length > before.ready) {
        found.ready = at;
        finish();
      } else requestAnimationFrame(check);
    };
    prompt.focus();
    if (!file) {
      // From the Cmd-V's key down to the page's paste event: the engine's read of the pasteboard.
      const keyDown = (event: KeyboardEvent) => {
        if (event.key.toLowerCase() === "v" && event.metaKey) start = performance.now();
      };
      window.addEventListener("keydown", keyDown, true);
      if (options.edit)
        window.addEventListener(
          "pointerdown",
          () => {
            start = performance.now();
            void callHost("pane.edit", { command: "paste" }).catch((error: unknown) => {
              result.edit_error = String(error);
            });
          },
          { capture: true, once: true },
        );
      window.addEventListener(
        "paste",
        (event) => {
          window.removeEventListener("keydown", keyDown, true);
          found.dispatched = since(start);
          // The engine's read of the pasteboard's picture: Blink reads it when the page asks for the
          // file (DataObjectItem::GetAsFile, the browser's ClipboardHost.ReadPng), not before.
          const reading = performance.now();
          const pasted = event.clipboardData?.files[0];
          found.read_ms = Math.round(performance.now() - reading);
          if (pasted) Object.assign(result, { bytes: pasted.size, type: pasted.type });
          requestAnimationFrame(check);
        },
        { capture: true, once: true },
      );
      return;
    }
    const data = new DataTransfer();
    data.items.add(file);
    prompt.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    found.dispatched = since(start);
    requestAnimationFrame(check);
  });
  Object.assign(result, marks);
  if (options.send && !options.real) {
    const watched = watchIds(options.watchMs ?? 8000);
    // Return in the prompt, with the pasted image in it: the prompt goes as the person's does.
    prompt.focus();
    prompt.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true, cancelable: true }),
    );
    const ids = await watched;
    result.ids_shown = ids.length;
    if (ids.length) result.ids = ids.slice(0, 20).join("\n");
  }
  // Each step of that path again, alone, now that the worker is warm.
  if (file) {
    result.preview_ms = await timed(() => prepareImageOffThread(file));
    result.instant_ms = await timed(() => instantPreview(file));
  }
  // The host's answers the composer asks for on a paste, by the composer's own path.
  result.dropped_ms = await timed(() => callHost("chat.attach.dropped", { kind: "paste", names: ["image.png"] }));
  result.source_ms = await timed(() =>
    callHost("chat.attach.source", { kind: "paste", names: ["image.png"], gestureAt: Date.now() }),
  );
  return result;
}

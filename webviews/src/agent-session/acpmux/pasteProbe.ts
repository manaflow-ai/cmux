// The DEBUG `debug.agent_pane paste_probe` verb (window.cmuxAcpmuxDebug.pasteProbe): pastes a
// Retina-sized screenshot into the composer through the page's own paste path and times what the
// person sees, then times the steps that path is made of, on this engine and with this host
// (https://github.com/manaflow-ai/cmux/issues/41016, "Cmd+V of an image is slow"). The pasteboard
// read itself is the engine's, before the paste event: a window that is never key cannot take a
// real Cmd-V, so it is not in these numbers.
import { instantPreview } from "./composer/attachmentIntakeModel";
import { prepareImageOffThread } from "./composer/imagePool";

export type PasteProbeOptions = { width?: number; height?: number; kind?: "text" | "noise" };

/// Milliseconds from the paste to each thing the composer shows, and how long each step took.
export type PasteProbeResult = Record<string, number | string | undefined>;

const PROMPT = ".acpmux-composer-prompt [contenteditable='true']";
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

const since = (start: number) => Math.round(performance.now() - start);

async function timed<T>(work: () => Promise<T>): Promise<number> {
  const start = performance.now();
  await work().catch(() => undefined);
  return since(start);
}

export async function pasteProbe(
  options: PasteProbeOptions,
  call: ((method: string, params?: Record<string, unknown>) => Promise<unknown>) | undefined,
): Promise<PasteProbeResult> {
  const prompt = document.querySelector<HTMLElement>(PROMPT);
  if (!prompt) return { error: "no composer prompt" };
  const file = await screenshot(options);
  const result: PasteProbeResult = { bytes: file.size };
  const marks = await new Promise<Record<string, number>>((resolve) => {
    const start = performance.now();
    const found: Record<string, number> = {};
    let stall = 0;
    let last = start;
    const beat = window.setInterval(() => {
      const now = performance.now();
      stall = Math.max(stall, now - last);
      last = now;
    }, 4);
    const deadline = window.setTimeout(() => finish(), 30_000);
    const finish = () => {
      window.clearInterval(beat);
      window.clearTimeout(deadline);
      resolve({ ...found, stall: Math.round(stall) });
    };
    const check = () => {
      const at = since(start);
      if (found.tile === undefined && document.querySelector(LOADING)) found.tile = at;
      const instant = document.querySelector<HTMLImageElement>(".acpmux-attachment-instant");
      if (found.instant === undefined && instant?.complete && instant.naturalWidth) found.instant = at;
      const ready = document.querySelector<HTMLImageElement>(READY_IMG);
      if (ready?.complete && ready.naturalWidth) {
        found.ready = at;
        finish();
      } else requestAnimationFrame(check);
    };
    prompt.focus();
    const data = new DataTransfer();
    data.items.add(file);
    prompt.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    found.dispatched = since(start);
    requestAnimationFrame(check);
  });
  Object.assign(result, marks);
  // Each step of that path again, alone, now that the worker is warm.
  result.preview_ms = await timed(() => prepareImageOffThread(file));
  result.instant_ms = await timed(() => instantPreview(file));
  if (call) {
    result.dropped_ms = await timed(() => call("chat.attach.dropped", { kind: "paste", names: [file.name] }));
    result.source_ms = await timed(() =>
      call("chat.attach.source", { kind: "paste", names: [file.name], gestureAt: Date.now() }),
    );
  }
  return result;
}

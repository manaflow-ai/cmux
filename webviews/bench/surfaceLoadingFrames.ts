// l10n-allow-file: benchmark output, not shipped UI.
// What a surface showed while it loaded, frame by frame, as bench/surface-loading.bench.ts reports it (Leo,
// 2026-11-10: "Anything fucking slow, anything fucking bullshit, anything with a stupid ass fucking loading state.").
// Pure, so test/surface-loading-frames.test.ts checks it without a browser.
//
// Each painted frame from navigation is one of:
//   blank    nothing a person could read or use: no visible text and no visible control, image or icon;
//   loading  a loading indicator in view: a spinner, a skeleton, `aria-busy`, a progress bar, or a line that only
//            says it is loading (LOADER_SELECTOR, LOADING_TEXT); content around it does not make it settled;
//   content  something to read or use, and no loading indicator in view. A small spinner (STATUS_SPINNER_PX or less)
//            beside readable content is one row's status (a machine connecting), not the surface loading: the frame
//            is content, and the spinner is named in `status`.
// A surface's time to content is when its settled content first painted: the first content frame after which no
// frame went back to blank or loading. One that never settled inside the window has none, and is held.

export type FrameState = "blank" | "loading" | "content";

export type SurfaceFrame = {
  /// `performance.now()` of the read: ms from navigation start.
  t: number;
  state: FrameState;
  /// What made a loading frame loading: each indicator's tag and class (`div.apps-skeleton-line`), at most a few.
  loaders?: string[];
  /// Small spinners beside content (row status), on a content frame.
  status?: string[];
};

/// The largest spinner, in CSS px on either side, read as a row's status when the frame has readable content.
export const STATUS_SPINNER_PX = 20;

/// Elements that are a loading state when in view. Class matches are on whole words of a class name (a
/// `spinner`, `skeleton`, `shimmer` or `loading` part), so `machines-spinner` and `cloud-loading` count and a
/// `downloading-file` row does not.
export const LOADER_SELECTOR = [
  '[aria-busy="true"]',
  '[role="progressbar"]',
  ".animate-spin",
  '[class*="spinner"]',
  '[class*="skeleton"]',
  '[class*="shimmer"]',
  '[class*="-loading"]',
  '[class^="loading"]',
  '[class*=" loading"]',
].join(",");

/// A line whose whole text says only that it is loading (any locale is English in the bench).
export const LOADING_TEXT = /^\s*(loading|connecting|fetching|please wait|starting)\b[^\n]{0,24}?(…|\.\.\.)?\s*$/i;

export type SurfaceMetrics = {
  frames: number;
  /// The first frame with content (ms from navigation), or null.
  firstContentMs: number | null;
  /// When the settled content first painted, or null when the surface was still blank or loading at the window's
  /// end (held).
  timeToContentMs: number | null;
  /// Painted time spent in a loading frame, and in a blank one, from the first frame to the window's end (or to
  /// settling): each frame counts until the next frame's read.
  loadingMs: number;
  blankMs: number;
  /// The longest unbroken run of loading frames (a spinner held this long), ms.
  longestLoadingMs: number;
  /// The window ended blank or loading: the surface never settled.
  held: boolean;
  /// The loading indicators seen, by how many frames showed each, most first.
  loaders: { name: string; frames: number }[];
  /// Row-status spinners seen on content frames, by frames, most first.
  status: { name: string; frames: number }[];
};

/// Judges a surface's painted frames, read until `endMs` (ms from navigation: the window's end).
export function classifySurface(frames: readonly SurfaceFrame[], endMs: number): SurfaceMetrics {
  const sorted = [...frames].sort((a, b) => a.t - b.t);
  let firstContentMs: number | null = null;
  let settledAt: number | null = null;
  let loadingMs = 0;
  let blankMs = 0;
  let longestLoadingMs = 0;
  let runStart: number | null = null;
  const loaders = new Map<string, number>();
  const status = new Map<string, number>();
  for (let i = 0; i < sorted.length; i += 1) {
    const frame = sorted[i];
    const next = i + 1 < sorted.length ? sorted[i + 1].t : Math.max(endMs, frame.t);
    const span = Math.max(0, next - frame.t);
    if (frame.state === "content") {
      for (const name of frame.status ?? []) status.set(name, (status.get(name) ?? 0) + 1);
      firstContentMs ??= frame.t;
      settledAt ??= frame.t;
      if (runStart !== null) longestLoadingMs = Math.max(longestLoadingMs, frame.t - runStart);
      runStart = null;
      continue;
    }
    settledAt = null;
    if (frame.state === "loading") {
      loadingMs += span;
      runStart ??= frame.t;
      for (const name of frame.loaders ?? []) loaders.set(name, (loaders.get(name) ?? 0) + 1);
    } else {
      blankMs += span;
      if (runStart !== null) longestLoadingMs = Math.max(longestLoadingMs, frame.t - runStart);
      runStart = null;
    }
  }
  const last = sorted.at(-1);
  if (runStart !== null) longestLoadingMs = Math.max(longestLoadingMs, Math.max(endMs, last?.t ?? 0) - runStart);
  const held = !last || last.state !== "content";
  return {
    frames: sorted.length,
    firstContentMs,
    timeToContentMs: held ? null : settledAt,
    loadingMs,
    blankMs,
    longestLoadingMs,
    held,
    loaders: byFrames(loaders),
    status: byFrames(status),
  };
}

const byFrames = (counts: Map<string, number>) =>
  [...counts].map(([name, frames]) => ({ name, frames })).sort((a, b) => b.frames - a.frames);

/// Median of the numbers (the mean of the middle two for an even count), or null for none.
export function median(values: readonly number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// The page-side reader: runs in the page (so it closes over nothing but its arguments) after each painted frame
/// and says what the frame showed. `loaderSelector` and `loadingText` are LOADER_SELECTOR and LOADING_TEXT's source.
export function readSurfaceFrame(
  loaderSelector: string,
  loadingText: string,
  statusPx: number,
): Omit<SurfaceFrame, "t"> {
  const textPattern = new RegExp(loadingText, "i");
  const vw = innerWidth;
  const vh = innerHeight;
  const shown = (el: Element): boolean => {
    const box = el.getBoundingClientRect();
    if (box.width < 1 || box.height < 1) return false;
    if (box.bottom <= 0 || box.right <= 0 || box.top >= vh || box.left >= vw) return false;
    const style = getComputedStyle(el);
    if (style.visibility === "hidden" || style.display === "none") return false;
    // An element fading in or out at opacity 0 shows nothing this frame (checkVisibility also walks ancestors).
    const check = (el as Element & { checkVisibility?: (o: object) => boolean }).checkVisibility;
    if (check && !check.call(el, { opacityProperty: true, visibilityProperty: true })) return false;
    return true;
  };
  const name = (el: Element) => {
    const raw = typeof el.className === "string" ? el.className : (el.getAttribute("class") ?? "");
    const cls = raw.trim().split(/\s+/).filter(Boolean).at(-1) ?? "";
    const busy = el.getAttribute("aria-busy") === "true" ? "[aria-busy]" : "";
    const role = el.getAttribute("role") === "progressbar" ? "[progressbar]" : "";
    return `${el.tagName.toLowerCase()}${cls ? `.${cls}` : ""}${busy}${role}`;
  };
  const body = document.body;
  if (!body) return { state: "blank" };
  const loaders: string[] = [];
  const small: string[] = [];
  for (const el of Array.from(body.querySelectorAll(loaderSelector))) {
    // `aria-busy` on a whole list while one row updates still draws the list: count it only when it holds no
    // readable text of its own, so a busy wrapper around drawn rows is content, and a busy empty box is loading.
    if (el.getAttribute("aria-busy") === "true" && (el.textContent ?? "").trim().length > 40) continue;
    // A spinner's own parts (an svg's arc path) are the spinner, not another loader.
    if (el.parentElement?.closest(loaderSelector)) continue;
    if (!shown(el)) continue;
    const box = el.getBoundingClientRect();
    const isSmall = box.width <= statusPx && box.height <= statusPx && !(el.textContent ?? "").trim();
    (isSmall ? small : loaders).push(name(el));
    if (loaders.length + small.length >= 8) break;
  }
  // Text nodes in view, and whether any line says only that it loads.
  let readable = 0;
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const text = node.textContent ?? "";
    if (!text.trim()) continue;
    const parent = node.parentElement;
    if (!parent || parent.closest("script,style,noscript,template")) continue;
    if (!shown(parent)) continue;
    if (textPattern.test(parent.textContent ?? "")) {
      if (loaders.length < 4) loaders.push(`${name(parent)}:"${text.trim().slice(0, 24)}"`);
      continue;
    }
    readable += text.trim().length;
    if (readable > 0 && loaders.length > 0) break;
  }
  if (loaders.length > 0) return { state: "loading", loaders };
  if (readable > 0) return small.length > 0 ? { state: "content", status: small.slice(0, 4) } : { state: "content" };
  // A small spinner alone on an empty page is the page loading.
  if (small.length > 0) return { state: "loading", loaders: small.slice(0, 4) };
  // No text: a control, image, icon or canvas in view is something to use.
  for (const el of Array.from(
    body.querySelectorAll("button,input,textarea,select,img,svg,canvas,video,[contenteditable]"),
  )) {
    if (shown(el)) return { state: "content" };
  }
  return { state: "blank" };
}

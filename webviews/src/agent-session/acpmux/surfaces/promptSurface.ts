/// This pane as one place a person types into a chat (acpmux `hub/composers.rs`,
/// cmuxterm-hq#2580). With preview features on (`labs.previewFeatures`, off by default) its prompts
/// carry `_meta.acpmux.surface`, so every other window, phone or CLI attached to the chat sees which
/// place sent each queued prompt (`_acpmux/composers`). Off, prompts go as before.

export type PromptSurface = { id: string; name: string; kind: "app" };

let labelled = false;
let surface: PromptSurface | undefined;

/// Preview features on or off (`applyPreview`).
export function setPromptSurfaces(on: boolean): void {
  labelled = on;
}

/// The device a page runs on, as acpmux shows it to the other places typing into the chat.
/// iPadOS Safari reports a Mac user agent; only its touch points tell it apart.
export function deviceName(userAgent: string, touchPoints = 0): string {
  if (/iPhone/.test(userAgent)) return "iPhone";
  if (/iPad/.test(userAgent) || (/Macintosh/.test(userAgent) && touchPoints > 1)) return "iPad";
  // l10n-allow: a device's product name, the same in every language.
  if (/Macintosh|Mac OS X/.test(userAgent)) return "Mac";
  return FALLBACK_NAME;
}

/// Any other browser. l10n-allow: the platform's name, not prose; acpmux shows it as sent.
const FALLBACK_NAME = "Web";

/// The `_meta.acpmux` keys a prompt from this pane adds: none while preview features are off.
/// The id lasts as long as the page, so each pane (each window) is its own surface.
export function promptSurfaceMeta(): { surface: PromptSurface } | Record<string, never> {
  if (!labelled) return {};
  surface ??= {
    id: crypto.randomUUID(),
    name: typeof navigator === "undefined" ? FALLBACK_NAME : deviceName(navigator.userAgent, navigator.maxTouchPoints),
    kind: "app",
  };
  return { surface };
}

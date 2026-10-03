// The local web page a turn started or mentioned: a dev server's "Local: http://localhost:5173/",
// a prompt asking about http://127.0.0.1:3000/admin, an answer pointing at it. The turn's preview
// card shows the latest one. Only loopback hosts the pane's frame may load qualify (the page's CSP
// `frame-src` and URL+AgentPanePreview.swift name the same ones); 0.0.0.0, which a server binds but a
// browser does not reach, reads as localhost.
//
// The text is not trusted: a shell call's output can carry a fetched page's words. So the card's
// frame, which loads without a click, only ever loads the page's root (`previewFrameUrl`); the
// full address waits for the reader's click (the link, Open in tab).
import type { AcpmuxRow } from "../model";

/// Height of the card's thumbnail (`.acpmux-turn-preview-frame` in styles.css); the page draws at four
/// times its size, scaled down.
export const PREVIEW_FRAME_HEIGHT = 180;

// The host ends the name (`localhost.evil.com` is not loopback, a sentence's closing dot is fine);
// a colon after it must start a port.
const LOCAL_URL =
  /\bhttps?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?![\w-]|\.[\w-])(?::\d{1,5}(?!\d)|(?!:))(?:[/?#][^\s"'`<>()[\]{}]*)?/gi;
/// Terminal colour codes, which dev servers print inside the address (`localhost:\x1b[1m5173`).
// eslint-disable-next-line no-control-regex
const ANSI = /\x1b\[[0-9;]*[A-Za-z]/g;

/// The latest loopback page in `texts`, normalized (trailing punctuation dropped, 0.0.0.0 as
/// localhost), or nil.
export function latestLocalUrl(texts: readonly (string | undefined)[]): string | undefined {
  let found: string | undefined;
  for (const text of texts) {
    if (!text) continue;
    for (const match of text.replace(ANSI, "").matchAll(LOCAL_URL)) {
      const url = parse(match[0].replace(/[.,;:!?*_]+$/, ""));
      if (url) found = url;
    }
  }
  return found;
}

function parse(text: string): string | undefined {
  try {
    const url = new URL(text);
    if (url.hostname === "0.0.0.0") url.hostname = "localhost";
    const port = url.port ? Number(url.port) : undefined;
    if (port !== undefined && (port < 1 || port > 65_535)) return undefined;
    return url.href;
  } catch {
    return undefined;
  }
}

/// The page a turn started or mentioned: its prompt, its answers, and its shell calls' commands
/// and output (where a dev server prints its address). Other tools' input and output (a file
/// read, a web fetch) are left out.
export function turnPreviewUrl(user: AcpmuxRow, turn: readonly AcpmuxRow[]): string | undefined {
  return latestLocalUrl([
    user.text,
    ...turn.flatMap((row) => [
      row.kind === "assistant" ? row.text : undefined,
      ...(row.items ?? []).flatMap((item) =>
        item.tool?.kind === "execute" ? [item.tool.command, item.tool.output] : [],
      ),
    ]),
  ]);
}

/// What the card's frame loads: the page's root, never the path or query the text named.
export function previewFrameUrl(url: string): string {
  return `${new URL(url).origin}/`;
}

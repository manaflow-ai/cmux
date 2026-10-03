// The local web page a turn started or mentioned: a dev server's "Local: http://localhost:5173/",
// a prompt asking about http://127.0.0.1:3000/admin, an answer pointing at it. The turn's preview
// card shows the latest one. Only loopback hosts the pane's frame may load qualify (the page's CSP
// `frame-src` and AgentPanePreview.swift name the same ones); 0.0.0.0, which a server binds but a
// browser does not reach, reads as localhost.
import type { AcpmuxRow } from "../model";

/// Height of the card's thumbnail (`.acpmux-preview-frame` in styles.css); the page draws at four
/// times its size, scaled down.
export const PREVIEW_FRAME_HEIGHT = 180;

const LOCAL_URL = /\bhttps?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?![\w.-])(?::\d{1,5}(?!\d))?(?:[/?#][^\s"'`<>()[\]{}]*)?/gi;

/// The latest loopback page in `texts`, normalized (trailing punctuation dropped, 0.0.0.0 as
/// localhost), or nil.
export function latestLocalUrl(texts: readonly (string | undefined)[]): string | undefined {
  let found: string | undefined;
  for (const text of texts) {
    if (!text) continue;
    for (const match of text.matchAll(LOCAL_URL)) {
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

/// The page a turn started or mentioned: its prompt, then its rows' text, tool commands and output.
export function turnPreviewUrl(user: AcpmuxRow, turn: readonly AcpmuxRow[]): string | undefined {
  return latestLocalUrl([
    user.text,
    ...turn.flatMap((row) => [
      row.kind === "assistant" ? row.text : undefined,
      ...(row.items ?? []).flatMap((item) => [item.tool?.command, item.tool?.output, item.tool?.inputSummary]),
    ]),
  ]);
}

// The local web page a turn started or mentioned: a dev server's "Local: http://localhost:5173/",
// a prompt asking about http://127.0.0.1:3000/admin, an answer pointing at it. The chat header's
// preview opens the latest one. Only loopback hosts the pane's frame may load qualify (the page's
// CSP `frame-src` and URL+AgentPanePreview.swift name the same ones); 0.0.0.0, which a server binds
// but a browser does not reach, reads as localhost.
import type { AcpmuxRow } from "../model";
import { stripAnsi } from "./toolOutput";

// The host ends the name (`localhost.evil.com` is not loopback, a sentence's closing dot is fine);
// a colon after it must start a port.
const LOCAL_URL =
  /\bhttps?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?![\w-]|\.[\w-])(?::\d{1,5}(?!\d)|(?!:))(?:[/?#][^\s"'`<>()[\]{}]*)?/gi;

// An address given as a setting's value is a service the agent talks to, not a page to look at:
// `ANTHROPIC_BASE_URL=http://127.0.0.1:31415` (a model gateway, Leo 2026-10-19), `"baseUrl":
// "http://localhost:8080"`, `--api-url http://...`, `proxy: http://...`.
const SETTING_BEFORE = [
  // An environment variable: `ANTHROPIC_BASE_URL=`, `PORT_URL="` (upper case only).
  /\b[A-Z][A-Z0-9_]*=["']?$/,
  // A quoted key: `"baseUrl": "`, `'api_endpoint': `.
  /["'][\w-]*(?:url|uri|endpoint|proxy|base)["']\s*[:=]\s*["']?$/i,
  // An identifier ending in one: `baseUrl = `, `api_url: `, `upstreamProxy=`.
  /\b[a-z][\w]*?(?:Url|URL|Uri|URI|Endpoint|Proxy|_url|_uri|_endpoint|_proxy)\s*[:=]\s*["']?$/,
  // A YAML or INI key on its own line: `proxy: `, `url = `.
  /(?:^|\n)\s*(?:url|uri|base|endpoint|proxy)\s*[:=]\s*["']?$/,
  // A command-line flag: `--api-url `, `--proxy=`, `--endpoint "`.
  /(?:^|\s)--(?:[\w-]*-)?(?:url|uri|endpoint|proxy|api|base)(?:-[\w-]+)?[=\s]["']?$/,
];
// An API route answers a program, not a reader: `/v1/messages`, `/api/...`, `/graphql`, `/rpc`.
const API_PATH = /^\/(?:v\d+(?:\/|$)|api(?:\/|$)|graphql(?:\/|$)|rpc(?:\/|$)|healthz?(?:\/|$))/i;

/// The latest loopback page in `texts`, normalized (trailing punctuation dropped, 0.0.0.0 as
/// localhost), or nil. Settings' values and API routes are not pages (SETTING_BEFORE, API_PATH).
export function latestLocalUrl(texts: readonly (string | undefined)[]): string | undefined {
  let found: string | undefined;
  for (const text of texts) {
    if (!text) continue;
    // Dev servers colour the address itself (`localhost:\x1b[1m5173`).
    const plain = stripAnsi(text);
    for (const match of plain.matchAll(LOCAL_URL)) {
      const before = plain.slice(Math.max(0, match.index - 64), match.index);
      if (SETTING_BEFORE.some((setting) => setting.test(before))) continue;
      const url = parse(match[0].replace(/[.,;:!?*_]+$/, ""));
      if (url && !API_PATH.test(new URL(url).pathname)) found = url;
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

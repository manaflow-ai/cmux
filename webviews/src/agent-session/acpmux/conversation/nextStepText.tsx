// The text of a next-step card (NextStepCard.tsx): its recap, question and muted line drawn as the
// transcript draws a reply's inline Markdown (inlineMarkdown.tsx renderInline), so a link is a link and
// a GitHub pull request or issue address is its `owner/repo#N` reference chip. A bare web address
// that is not one gets a short label first (`host/…/last`), so a recap naming a dashboard or a CI
// run reads as one short link instead of a raw address wrapped over two lines
// (https://github.com/manaflow-ai/cmux/issues/38134). Answer buttons keep question/inlineText.tsx:
// a link inside a button would take the click that answers it.
import type { ReactNode } from "react";
import { githubRefLabel } from "../chips/linkChipsModel";
import { renderInline } from "./inlineMarkdown";

// Code spans and Markdown links are kept as written (group 1); otherwise a bare http(s) address. It
// may hold one level of parentheses (`…/Foo_(bar)`) and never ends on sentence punctuation or on
// the `*` / `~` of a bold or struck mark around it (`**https://x.test/a**`).
const URL_CHAR = '[^\\s<>()[\\]`"]';
const URL_PARENS = `\\(${URL_CHAR}*\\)`;
const URL_END = "[^\\s<>()[\\]`\".,;:!?'*~]";
const ADDRESS = new RegExp(
  "(`[^`\\n]*`|!?\\[[^\\]\\n]*\\]\\((?:[^()\\n]|\\([^()\\n]*\\))*\\)|<https?:\\/\\/[^>\\s]*>)" +
    `|\\bhttps?:\\/\\/(?:${URL_CHAR}|${URL_PARENS})*(?:${URL_END}|${URL_PARENS})`,
  "g",
);
const MAX_TAIL = 32;

/// A short label for a web address: its host (no `www.`) and the last part of its path, with `…`
/// for the parts between. Undefined for an address that does not parse.
export function shortLinkLabel(href: string): string | undefined {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return undefined;
  }
  if (!url.hostname) return undefined;
  const host = url.hostname.replace(/^www\./, "");
  const parts = url.pathname.split("/").filter(Boolean);
  const last = parts.at(-1);
  if (!last) return host;
  const tail = last.length > MAX_TAIL ? `${last.slice(0, MAX_TAIL - 1)}…` : last;
  return parts.length > 1 ? `${host}/…/${tail}` : `${host}/${tail}`;
}

/// `text` with each bare web address that is not a GitHub pull request or issue written as a
/// Markdown link with its short label. Code, existing links and autolinks are left as they are.
export function shortLinks(text: string): string {
  if (!text.includes("://")) return text;
  return text.replace(ADDRESS, (whole, kept: string | undefined) => {
    if (kept || githubRefLabel(whole)) return whole;
    const label = shortLinkLabel(whole);
    // The label is text: a `*` or `_` in a path is not a mark there.
    return label ? `[${label.replace(/[\\`*_~]/g, "\\$&")}](${whole})` : whole;
  });
}

/// A next-step card's recap, question or muted line, drawn.
export function nextStepText(text: string): ReactNode {
  return renderInline(shortLinks(text));
}

// A browser pick's data (composer/BrowserPickChip.tsx): whether a text attachment is one, what its
// card says, and the chip's rows. The browser's element picker (Swift BrowserDesignModeCards) sends
// each pick as one text attachment whose text is the whole card: its number, the person's comment,
// the page and the element. The prompt sends that card whole (attachments.ts `promptText`), its
// crop after it; the chip is only how it is drawn: the pick's number (the pin on the page), its
// comment, and the element and page under it. David Beyer, 2026-11-20: "I like the way Codex does it".
import type { Translate } from "../i18n";
import type { ChipLabelPart } from "./contentChipModel";
import { pickSnippet } from "./uiPickModel";

/// The card's first line (Swift BrowserDesignModeCards `agentText`).
export const BROWSER_PICK_HEADER = "Design mode highlight from the cmux browser.";
/// The id prefix of a pick's attachment (Swift BrowserDesignModeCards: `design-<hash>`).
const ID_PREFIX = "design-";

/// What a card says; a field the card leaves out is unset.
export type BrowserPick = { number?: number; comment?: string; tag?: string; host?: string; text?: string };

/// The labelled lines of a card. A value may run over several lines, up to the next label.
const LABEL =
  /^(Pick|Comment|Page|Element|Selector|Other selectors|XPath|React components|Component source|Text|Computed styles|HTML|Edits made in design mode): ?(.*)$/;

/// Whether a text attachment (or a sent block's name and body) is a browser pick: its id is the
/// picker's, or its text is a pick's card.
export function isBrowserPick(attachment: { id?: string; text?: string }): boolean {
  if (attachment.id?.startsWith(ID_PREFIX) && attachment.text !== undefined) return true;
  return firstLine(attachment.text ?? "") === BROWSER_PICK_HEADER;
}

/// The card's fields.
export function parseBrowserPick(card: string): BrowserPick | undefined {
  const lines = card.split(/\r\n|\n|\r/);
  const start = lines.findIndex((line) => line.trim() === BROWSER_PICK_HEADER);
  if (start < 0) return undefined;
  const fields = new Map<string, string>();
  let current: string | undefined;
  for (const line of lines.slice(start + 1)) {
    const match = LABEL.exec(line);
    if (match) {
      current = match[1]!;
      if (!fields.has(current)) fields.set(current, match[2]!);
      else current = undefined;
    } else if (current) fields.set(current, `${fields.get(current)!}\n${line}`);
  }
  const value = (key: string) => fields.get(key)?.trim() || undefined;
  const pick: BrowserPick = {};
  const number = Number.parseInt(value("Pick") ?? "", 10);
  if (Number.isFinite(number) && number > 0) pick.number = number;
  const comment = value("Comment");
  if (comment) pick.comment = comment;
  const tag = value("Element")?.replace(/^<|>$/g, "");
  if (tag) pick.tag = tag;
  const host = hostOf(value("Page"));
  if (host) pick.host = host;
  const text = value("Text");
  if (text) pick.text = text.replace(/\s+/g, " ");
  return pick;
}

/// The chip's rows: the pick's number (its badge), the title (the comment, or with none the element
/// and a snippet of its text) and the caption (the kind, the element, the page). A card that does not
/// parse reads as the attachment's name over the kind.
export function browserPickRows(
  t: Translate,
  name: string,
  card: string,
): { number?: number; title: ChipLabelPart[]; caption: ChipLabelPart[] } {
  const kind: ChipLabelPart = { part: "kind", text: t("composer.browserPick.kind") };
  const pick = parseBrowserPick(card);
  if (!pick) return { title: [{ part: "name", text: name }], caption: [kind] };
  const element: ChipLabelPart[] = pick.tag ? [{ part: "element", text: pick.tag }] : [];
  const host: ChipLabelPart[] = pick.host ? [{ part: "host", text: pick.host }] : [];
  const number = pick.number === undefined ? {} : { number: pick.number };
  if (pick.comment)
    return { ...number, title: [{ part: "comment", text: pick.comment }], caption: [kind, ...element, ...host] };
  const snippet: ChipLabelPart[] = pick.text
    ? [{ part: "snippet", text: t("composer.uiPick.snippet", { text: pickSnippet(pick.text) }) }]
    : [];
  return {
    ...number,
    title: [{ part: "name", text: pick.tag ?? name }, ...snippet],
    caption: [kind, ...host],
  };
}

function hostOf(page: string | undefined): string | undefined {
  if (!page) return undefined;
  try {
    const url = new URL(page);
    if (url.protocol === "file:") return decodeURIComponent(url.pathname.split("/").pop() ?? "") || undefined;
    return url.host || undefined;
  } catch {
    return undefined;
  }
}

function firstLine(text: string): string {
  const end = text.search(/\r|\n/);
  return (end < 0 ? text : text.slice(0, end)).trim();
}

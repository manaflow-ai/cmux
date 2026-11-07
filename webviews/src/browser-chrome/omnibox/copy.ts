// What Copy and Cut put on the pasteboard for the omnibar's selection (OmnibarRules.swift,
// Chromium `omnibox::AdjustTextForCopy`).
import { clamped } from "./rules";
import { displayText, fieldText, hasFocus, isPopupOpen, permanentText } from "./state";
import type { OmnibarState } from "./state";
import type { OmniboxResolver } from "./types";
import { urlHost, urlScheme } from "./url-display";

export interface OmnibarCopy {
  text: string;
  /** Also written as a URL (a hyperlink to the page). */
  url: string | null;
}

const isHTTP = (url: string): boolean => urlScheme(url) === "http" || urlScheme(url) === "https";

/**
 * Copy of the field's selection, null when nothing is selected. A selection that does not start at
 * the beginning copies as is; the whole untouched URL copies the page URL; otherwise text that
 * reads as a URL on the page's (or the arrowed row's) host gets that page's scheme.
 */
export function copyContent(state: OmnibarState, resolver: OmniboxResolver): OmnibarCopy | null {
  if (!hasFocus(state)) return null;
  const text = fieldText(state);
  const selection = clamped(state.edit.selection, text.length);
  if (selection.length === 0) return null;
  const selected = text.slice(selection.location, selection.location + selection.length);
  if (selection.location !== 0) return { text: selected, url: null };
  const modified = state.phase !== "focused" || (selected !== displayText(state) && selected !== permanentText(state));
  if (!modified && state.pageURL != null) return { text: state.pageURL, url: state.pageURL };
  const destination = resolver.destination(selected);
  if (destination?.kind !== "url") return { text: selected, url: null };
  let url = destination.url;
  let current = state.pageURL;
  const { selected: row, rows } = state.popup;
  if (isPopupOpen(state) && row != null && row < rows.length && rows[row].kind !== "search") current = rows[row].url;
  if (current == null || !isHTTP(current) || !isHTTP(url) || urlHost(current) !== urlHost(url)) {
    return { text: selected, url: null };
  }
  const lowered = selected.toLowerCase();
  if (!lowered.startsWith("http://") && !lowered.startsWith("https://")) {
    const scheme = current.slice(0, current.indexOf(":"));
    url = scheme + url.slice(url.indexOf(":"));
  }
  return { text: url, url };
}

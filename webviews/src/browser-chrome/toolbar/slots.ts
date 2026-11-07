// Each tab slot's resting omnibar (Chromium `OmniboxView::SaveStateToTab`): the toolbar page keeps
// one state per `tab` and puts it back when the pane shows that tab again. Least recently used
// slots go first past the cap, so memory stays bounded however many tabs come and go.
//
// A tab that moves to another pane leaves its slot in this page; the text it left unsent travels with
// it as a draft: the page reports the shown tab's draft in each status, the host keeps it on the tab
// (`BrowserChromeTabState.omnibarDraft`) when the tab leaves, and the destination page, which has no
// slot for the tab, rests the omnibar on it.
import { clamped } from "../omnibox/rules";
import { displayText, visibleUserText, type OmnibarState } from "../omnibox/state";
import type { OmnibarDraft } from "./wire";

export const TAB_SLOT_LIMIT = 256;

export class TabSlotStore {
  private readonly slots = new Map<string, OmnibarState>();

  constructor(private readonly limit = TAB_SLOT_LIMIT) {}

  get size(): number {
    return this.slots.size;
  }

  /** The slot's state, now the most recently used; undefined for a slot never stored. */
  get(tab: string): OmnibarState | undefined {
    const state = this.slots.get(tab);
    if (state === undefined) return undefined;
    this.slots.delete(tab);
    this.slots.set(tab, state);
    return state;
  }

  set(tab: string, state: OmnibarState): void {
    this.slots.delete(tab);
    this.slots.set(tab, state);
    while (this.slots.size > this.limit) {
      const oldest = this.slots.keys().next().value;
      if (oldest === undefined) break;
      this.slots.delete(oldest);
    }
  }

  delete(tab: string): void {
    this.slots.delete(tab);
  }

  has(tab: string): boolean {
    return this.slots.has(tab);
  }
}

/**
 * The text a tab would leave behind if focus left now, with its selection (what `focusLost` keeps
 * as `retainedText` and `savedSelection`); null when it would show its address again.
 */
export function draftOf(state: OmnibarState): OmnibarDraft | null {
  switch (state.phase) {
    case "idle":
      if (state.retainedText == null) return null;
      return { text: state.retainedText, selection: wireRange(state.savedSelection, state.retainedText.length) };
    case "editing": {
      // A keyword session's text means nothing without its keyword (`focusLost` drops it).
      if (state.keyword != null) return null;
      const text = visibleUserText(state);
      if (text === "" || text === displayText(state)) return null;
      return { text, selection: wireRange(state.edit.selection, text.length) };
    }
    default:
      return null;
  }
}

/** A tab's fresh resting omnibar with the draft it brought from another pane (none: unchanged). */
export function withDraft(state: OmnibarState, draft: OmnibarDraft | null | undefined): OmnibarState {
  if (!draft || draft.text === "") return state;
  const [location, length] = draft.selection;
  return { ...state, retainedText: draft.text, savedSelection: clamped({ location, length }, draft.text.length) };
}

export function draftsEqual(a: OmnibarDraft | null, b: OmnibarDraft | null): boolean {
  if (a === null || b === null) return a === b;
  return a.text === b.text && a.selection[0] === b.selection[0] && a.selection[1] === b.selection[1];
}

function wireRange(selection: { location: number; length: number } | null, length: number): [number, number] {
  const range = selection ? clamped(selection, length) : { location: length, length: 0 };
  return [range.location, range.length];
}

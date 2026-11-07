// Runs the omnibar state machine for the toolbar page (UI/OmnibarController.swift): reduces inputs
// in FIFO order, applies the presentation through the effect applier (the field, and the card as a
// `popup` command), then hands every effect to the host in order and the status when it changed.
// Inputs raised while a step runs (a focus change a commit causes) queue behind it, so the reducer
// is never re-entered.
import { OmnibarEffectApplier, type OmnibarFieldSurface, type OmnibarPopupSurface } from "../omnibox/effect-applier";
import { presentation, type OmnibarPresentation } from "../omnibox/presentation";
import { reduce } from "../omnibox/reducer";
import { fieldText, hasFocus, isPopupOpen, highlightedRow, type OmnibarState } from "../omnibox/state";
import type { BrowserSuggestion, OmnibarEffect, OmnibarInput, OmniboxResolver } from "../omnibox/types";
import { draftOf, draftsEqual } from "./slots";
import type { ToolbarPageCommand } from "./wire";

type StatusCommand = Extract<ToolbarPageCommand, { type: "status" }>;

export type OmnibarRunnerOptions = {
  field: OmnibarFieldSurface;
  /** Sends a command to the host. */
  post: (command: ToolbarPageCommand) => void;
  /** The resolver the reducer uses now. */
  resolver: () => OmniboxResolver;
  /** The card opens above the bar. */
  upward: () => boolean;
  /** "Search %@" for an engine keyword's chip. */
  labelForEngine?: (engine: string) => string;
  /** Effects the page runs itself too (before they go to the host). */
  onEffect?: (effect: OmnibarEffect) => void;
  /** After every step and restore (the page redraws). */
  onStep?: () => void;
  /** The tab slot the state belongs to (the status names it). */
  tab?: () => string | null;
};

/** The status the host reads synchronously (phase, text, card, the tab's draft), from a state. */
export function statusOf(state: OmnibarState, tab: string | null = null): StatusCommand {
  const focused = hasFocus(state);
  const open = isPopupOpen(state);
  const selection = state.edit.selection;
  return {
    type: "status",
    phase: state.phase,
    editing: focused,
    popupOpen: open,
    text: fieldText(state),
    selection: focused ? [selection.location, selection.length] : null,
    elided: state.elided,
    rows: open ? state.popup.rows.map((row) => row.title) : [],
    highlighted: open ? highlightedRow(state.popup) : null,
    tab,
    draft: draftOf(state),
  };
}

function statusEqual(a: StatusCommand, b: StatusCommand): boolean {
  return (
    a.phase === b.phase &&
    a.editing === b.editing &&
    a.popupOpen === b.popupOpen &&
    a.text === b.text &&
    a.elided === b.elided &&
    a.highlighted === b.highlighted &&
    a.tab === b.tab &&
    draftsEqual(a.draft, b.draft) &&
    (a.selection === b.selection ||
      (a.selection !== null &&
        b.selection !== null &&
        a.selection[0] === b.selection[0] &&
        a.selection[1] === b.selection[1])) &&
    a.rows.length === b.rows.length &&
    a.rows.every((row, index) => row === b.rows[index])
  );
}

export class OmnibarRunner {
  state: OmnibarState;
  readonly applier: OmnibarEffectApplier;
  /** True while the applier writes: field events are its echo. */
  applying = false;
  private queue: OmnibarInput[] = [];
  private running = false;
  private lastStatus: StatusCommand | null = null;
  private shownRows: readonly BrowserSuggestion[] = [];

  constructor(
    initial: OmnibarState,
    private readonly options: OmnibarRunnerOptions,
  ) {
    this.state = initial;
    const popup: OmnibarPopupSurface = {
      showRows: (rows, highlighted) => {
        this.shownRows = rows;
        this.postPopup(rows, highlighted);
      },
      highlightRow: (row) => this.postPopup(this.shownRows, row),
      dismissRows: () => {
        this.shownRows = [];
        this.postPopup([], null);
      },
    };
    this.applier = new OmnibarEffectApplier(options.field, popup);
  }

  get presentation(): OmnibarPresentation {
    return presentation(this.state, this.options.labelForEngine);
  }

  /**
   * Reduces `input`. Returns whether it was handled (keys: false lets the input run its default).
   * An input sent while a step runs is queued and reports false.
   */
  send(input: OmnibarInput): boolean {
    if (this.running) {
      this.queue.push(input);
      return false;
    }
    this.running = true;
    try {
      const handled = this.step(input);
      while (this.queue.length > 0) this.step(this.queue.shift() as OmnibarInput);
      return handled;
    } finally {
      this.running = false;
    }
  }

  /** Puts back a tab slot's resting state: no input, no effects; the field and bar show it at once. */
  restore(resting: OmnibarState): void {
    this.queue = [];
    this.state = resting;
    this.applyPresentation();
    this.finishStep();
  }

  private step(input: OmnibarInput): boolean {
    const transition = reduce(this.state, input, this.options.resolver());
    this.state = transition.state;
    this.applyPresentation();
    for (const effect of transition.effects) {
      this.options.onEffect?.(effect);
      this.options.post({ type: "effect", effect });
    }
    this.finishStep();
    return transition.handled;
  }

  private applyPresentation(): void {
    this.applying = true;
    try {
      this.applier.apply(this.presentation);
    } finally {
      this.applying = false;
    }
  }

  private finishStep(): void {
    const status = statusOf(this.state, this.options.tab?.() ?? null);
    if (this.lastStatus === null || !statusEqual(this.lastStatus, status)) {
      this.lastStatus = status;
      this.options.post(status);
    }
    this.options.onStep?.();
  }

  private postPopup(rows: readonly BrowserSuggestion[], highlighted: number | null): void {
    this.options.post({ type: "popup", rows: [...rows], highlighted, upward: this.options.upward() });
  }
}

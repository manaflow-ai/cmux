// The interaction state of one question card: which item is shown, which row is highlighted,
// what is chosen and the Other drafts. A pure reducer, ported 1:1 from the Swift
// AgentQuestionCardState (Packages/Shared/CmuxAgentQuestion), so keyboard behavior is the same
// in the Mac card and the agent tab.
//
// Rows of an item are its options, then one "Other" row when the item allows free text. Only
// `sendCard` with a person's key or click produces a `submit` effect; nothing answers on a timer
// or by default.
import { answerProblems, isPending, selection, type AgentQuestion, type Answer, type Item, type Option } from "./model";

export type CardState = {
  readonly question: AgentQuestion;
  /// Index of the item on screen (a card with several items shows one at a time).
  readonly activeItem: number;
  /// Highlighted row per item id.
  readonly highlighted: Readonly<Record<string, number>>;
  /// Chosen option ids per item id (a set; the answer orders them as the item lists them).
  readonly chosen: Readonly<Record<string, readonly string[]>>;
  readonly otherDrafts: Readonly<Record<string, string>>;
  /// True while the Other text field of the active item has the keyboard.
  readonly editingOther: boolean;
};

export type CardInput =
  /// 1-9: the row at that position.
  | { type: "number"; value: number }
  | { type: "up" }
  | { type: "down" }
  /// Previous or next item.
  | { type: "previousItem" }
  | { type: "nextItem" }
  /// Enter: choose the highlighted row, then advance or submit.
  | { type: "confirm" }
  /// Space: toggle the highlighted row (multi-select) or choose it.
  | { type: "toggle" }
  /// A click on a row.
  | { type: "click"; row: number }
  /// Text typed into the active item's Other field.
  | { type: "otherText"; text: string }
  | { type: "escape" }
  /// The explicit Submit button.
  | { type: "submit" };

export type CardEffect =
  | { type: "none" }
  /// Send this answer (built from a person's gesture).
  | { type: "submit"; answer: Answer }
  /// The Other field should take the keyboard.
  | { type: "beginOtherEditing" }
  /// Give the keyboard back to the composer.
  | { type: "resign" };

const NONE: CardEffect = { type: "none" };

export function cardState(question: AgentQuestion): CardState {
  return { question, activeItem: 0, highlighted: {}, chosen: {}, otherDrafts: {}, editingOther: false };
}

/// The item on screen.
export const activeItem = (state: CardState): Item | undefined => state.question.items[state.activeItem];

export const rowCount = (item: Item): number => item.options.length + (item.allowsOther ? 1 : 0);

export const isOtherRow = (row: number, item: Item): boolean => item.allowsOther && row === item.options.length;

/// The highlighted row of `item`, the active item by default.
export function highlightedRow(state: CardState, item: Item | undefined = activeItem(state)): number {
  return item ? (state.highlighted[item.id] ?? 0) : 0;
}

export const isChosen = (state: CardState, option: Option, item: Item): boolean =>
  state.chosen[item.id]?.includes(option.id) === true;

/// The selection of every item so far.
export function cardAnswer(state: CardState): Answer {
  const selections: Answer["selections"] = {};
  for (const item of state.question.items) {
    const chosen = state.chosen[item.id] ?? [];
    const ids = item.options.map((option) => option.id).filter((id) => chosen.includes(id));
    selections[item.id] = selection(ids, state.otherDrafts[item.id]);
  }
  return { selections };
}

export const canSubmit = (state: CardState): boolean =>
  isPending(state.question) && answerProblems(state.question, cardAnswer(state)).length === 0;

/// Replaces the question (for example when the owner's answered state arrives) and keeps the
/// local choices for a still-pending ask.
export function updateCard(state: CardState, question: AgentQuestion): CardState {
  return {
    ...state,
    question,
    activeItem: Math.min(state.activeItem, Math.max(question.items.length - 1, 0)),
    editingOther: isPending(question) ? state.editingOther : false,
  };
}

type Step = { state: CardState; effect: CardEffect };

/// Applies one input; returns the next state and what the renderer should do.
export function sendCard(state: CardState, input: CardInput): Step {
  const item = activeItem(state);
  if (!isPending(state.question) || !item)
    return { state, effect: input.type === "escape" ? { type: "resign" } : NONE };
  const rows = rowCount(item);
  const highlight = (row: number): CardState => ({ ...state, highlighted: { ...state.highlighted, [item.id]: row } });
  switch (input.type) {
    case "number": {
      if (input.value < 1 || input.value > rows) return { state, effect: NONE };
      return choose(highlight(input.value - 1), input.value - 1, item, !item.multiSelect);
    }
    case "up":
      return { state: highlight(Math.max(highlightedRow(state, item) - 1, 0)), effect: NONE };
    case "down":
      return { state: highlight(Math.min(highlightedRow(state, item) + 1, rows - 1)), effect: NONE };
    case "previousItem":
      return { state: { ...state, editingOther: false, activeItem: Math.max(state.activeItem - 1, 0) }, effect: NONE };
    case "nextItem":
      return {
        state: {
          ...state,
          editingOther: false,
          activeItem: Math.min(state.activeItem + 1, state.question.items.length - 1),
        },
        effect: NONE,
      };
    case "toggle":
      return choose(state, highlightedRow(state, item), item, false);
    case "click": {
      if (input.row < 0 || input.row >= rows) return { state, effect: NONE };
      return choose(highlight(input.row), input.row, item, !item.multiSelect);
    }
    case "confirm":
      if (state.editingOther) return advance({ ...state, editingOther: false });
      // Multi-select: Enter ends this item's choices (Space toggles).
      if (item.multiSelect) return advance(state);
      return choose(state, highlightedRow(state, item), item, true);
    case "otherText": {
      if (!item.allowsOther) return { state, effect: NONE };
      const next: CardState = { ...state, otherDrafts: { ...state.otherDrafts, [item.id]: input.text } };
      if (!item.multiSelect && input.text.trim()) return { state: withChosen(next, item, []), effect: NONE };
      return { state: next, effect: NONE };
    }
    case "escape":
      if (state.editingOther) return { state: { ...state, editingOther: false }, effect: NONE };
      return { state, effect: { type: "resign" } };
    case "submit":
      return { state, effect: canSubmit(state) ? { type: "submit", answer: cardAnswer(state) } : NONE };
  }
}

const withChosen = (state: CardState, item: Item, ids: readonly string[]): CardState => ({
  ...state,
  chosen: { ...state.chosen, [item.id]: ids },
});

function choose(state: CardState, row: number, item: Item, shouldAdvance: boolean): Step {
  if (isOtherRow(row, item)) {
    const editing = { ...state, editingOther: true };
    return { state: item.multiSelect ? editing : withChosen(editing, item, []), effect: { type: "beginOtherEditing" } };
  }
  const option = item.options[row]!.id;
  let next: CardState;
  if (item.multiSelect) {
    const current = state.chosen[item.id] ?? [];
    next = withChosen(
      state,
      item,
      current.includes(option) ? current.filter((id) => id !== option) : [...current, option],
    );
  } else {
    const { [item.id]: _dropped, ...drafts } = state.otherDrafts;
    next = { ...withChosen(state, item, [option]), otherDrafts: drafts };
  }
  return shouldAdvance ? advance(next) : { state: next, effect: NONE };
}

/// Moves to the next unanswered item, or submits when every item is answered.
function advance(state: CardState): Step {
  const answer = cardAnswer(state);
  const items = state.question.items;
  const unanswered = (index: number) => {
    const chosen = answer.selections[items[index]!.id];
    return !chosen || (chosen.optionIDs.length === 0 && !chosen.other);
  };
  const indices = items.map((_, index) => index);
  const next =
    indices.find((index) => index > state.activeItem && unanswered(index)) ??
    indices.find((index) => unanswered(index));
  if (next !== undefined)
    return { state: next === state.activeItem ? state : { ...state, activeItem: next }, effect: NONE };
  return { state, effect: canSubmit(state) ? { type: "submit", answer } : NONE };
}

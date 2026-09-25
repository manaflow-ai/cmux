export type TypingState = {
  readonly phraseIndex: number;
  readonly charIndex: number;
  readonly deleting: boolean;
};

export type TypingAction =
  | { readonly type: "start-deleting" }
  | { readonly type: "finish-deleting"; readonly phraseCount: number }
  | { readonly type: "advance" };

export function reduceTypingState(
  state: TypingState,
  action: TypingAction,
): TypingState {
  switch (action.type) {
    case "start-deleting":
      return { ...state, deleting: true };
    case "finish-deleting":
      return {
        ...state,
        phraseIndex: (state.phraseIndex + 1) % action.phraseCount,
        deleting: false,
      };
    case "advance":
      return {
        ...state,
        charIndex: state.charIndex + (state.deleting ? -1 : 1),
      };
  }
}

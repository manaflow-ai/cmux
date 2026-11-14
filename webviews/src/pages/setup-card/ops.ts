// The Set Up cmux card's protocol (cmux-page://cmux.setup-card/, host: CmuxNextApp HomeSetupCard).
// The host sends the rows' state as values (setupModel.ts `SetupState`); the card owns its words.
import type { SetupAction, SetupState } from "../home-messages/cards/setup/setupModel";

export const SETUP_OPS = {
  /** `{}` → `SetupState`. */
  state: "cmux.setup.state",
  /** Stream: the whole `SetupState` after each change. */
  changed: "cmux.setup.changed",
  /** `{action}`: a row's button (`SetupAction`), on the person's own click only. */
  run: "cmux.setup.run",
  /** `{}`: Hide; the card leaves for good, on the person's own click only. */
  hide: "cmux.setup.hide",
  /** `{height}`: the card's height in CSS px, after each layout change; the host sizes the view to it. */
  size: "cmux.setup.size",
  /** `{}`: the page gained focus (back from a sign-in): the host checks the sign-ins again. */
  focused: "cmux.setup.focused",
} as const;

export interface SetupOps {
  [SETUP_OPS.state]: { params: Record<string, never>; result: SetupState };
  [SETUP_OPS.run]: { params: { action: SetupAction }; result: Record<string, never> };
  [SETUP_OPS.hide]: { params: Record<string, never>; result: Record<string, never> };
  [SETUP_OPS.size]: { params: { height: number }; result: Record<string, never> };
  [SETUP_OPS.focused]: { params: Record<string, never>; result: Record<string, never> };
}

import { callNative } from "../callNative";
import type { HybridBlockedWhy } from "./hybridModel";

/// A blocked control's click: Signed Out opens Sign In (the pane's `palette.auth.signIn`, a connect action). The other
/// reasons have no action wired yet, so their click does nothing.
export function blockedAction(why: HybridBlockedWhy): void {
  if (why === "signed-out") void callNative("action.run", { id: "palette.auth.signIn" }).catch(() => undefined);
}

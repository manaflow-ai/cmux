import { callNative } from "../callNative";
import type { PlaceKeep } from "../place/placeModel";
import type { HybridBlockedWhy } from "./hybridModel";

/// A blocked control's click: Signed Out opens Sign In (the pane's `palette.auth.signIn`, a connect action). The other
/// reasons have no action wired yet, so their click does nothing.
export function blockedAction(why: HybridBlockedWhy): void {
  if (why === "signed-out") void callNative("action.run", { id: "palette.auth.signIn" }).catch(() => undefined);
}

/// What choosing Hybrid again asks for: Keep Running off when it is on (lit or waiting), else on. A slept chat's click
/// always turns it on (its tooltip says so).
export function nextPriority(keep: PlaceKeep, why?: HybridBlockedWhy): "high" | "normal" {
  return why === "slept" || keep.priority !== "high" ? "high" : "normal";
}

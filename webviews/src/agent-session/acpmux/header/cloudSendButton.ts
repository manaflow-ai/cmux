// The chat header's Send to Cloud button (cmux#55788): one click moves a chat on this Mac to a Cloud
// machine through the app's Move to Cloud (`cloudMove`, CmuxNextApp CloudMove.swift), the same action
// as the title menu's row and the palette's. That action picks or starts the machine, copies the
// chat's folder (a GitHub checkout is cloned there and gets this Mac's commits and uncommitted
// changes; any other folder is copied), moves the session with its history, draft and queue, and
// reopens the chat on the machine with its cloud mark. Pure: what the button shows, from what the
// app already reports in `pane.tabState`.
import type { OffloadKind, OffloadReasons } from "../environments";
import type { PlaceState } from "../place/placeModel";

export type CloudSendState =
  /// A click moves the chat now.
  | "ready"
  /// The app would refuse the move now (no first message yet, Cloud turned off): the button is
  /// greyed and says why.
  | "refused"
  /// This chat's move to Cloud is running: the button is greyed; the move card over the composer
  /// (place/MoveProgress.tsx) shows its steps.
  | "moving";

export interface CloudSendButton {
  readonly state: CloudSendState;
  /// The app's reason, while `refused`.
  readonly reason?: string;
}

/// What the button shows for `session`, or nothing when the chat has no move to Cloud: a Cloud
/// chat's tab hides Move to Cloud (CloudMove.hiddenMenuItems), so the button never shows on a chat
/// already in Cloud or in a page with no chat. A chat of another machine the app does not hide it
/// for gets the greyed button with the app's reason.
export function cloudSendButton({
  session,
  offloads,
  reasons,
  place,
}: {
  session: string | undefined;
  /// The moves the chat's own menu offers now (App.tsx `offloads`).
  offloads: readonly OffloadKind[];
  /// Why each offered move would refuse now (App.tsx `offloadReasons`).
  reasons: OffloadReasons;
  /// Where the chat runs and its move, as the app reports it (header/headerState.ts `place`).
  place: PlaceState | undefined;
}): CloudSendButton | undefined {
  if (!session || !offloads.includes("move")) return undefined;
  const move = place?.move;
  if (move && move.direction === "toCloud" && move.state === "moving" && (!move.session || move.session === session))
    return { state: "moving" };
  const reason = reasons.move;
  return reason ? { state: "refused", reason } : { state: "ready" };
}

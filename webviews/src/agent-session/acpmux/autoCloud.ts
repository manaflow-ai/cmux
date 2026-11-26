/// AutoCloud (Leo, 2026-11-24, of the new-chat place picker: "let's just use our existing dropdown and
/// have it be able to have a chevron that opens into more options"): with the Cloud plan and the
/// `cloud.autoCloud` key (Settings > Machines, Auto Places Chats in Cloud; default off), the Where
/// menu's Auto row opens a list of its own: Auto (this Mac when it has room, else a Cloud VM), Cloud only, and Machine…, picked with ⌥⌘1,
/// ⌥⌘2 and ⌥⌘3 while that list is open. Off, the menu is as it was. Auto's pick and its Send are
/// Auto's own (autoWhereModel.ts); this file only decides whether the chevron shows and which row a
/// digit names.
import type { CloudPlanView } from "./cloudPlans";

/// The Auto list's rows, in order; a digit names the row at its place (⌥⌘1 is the first).
export type AutoPlaceRow = "auto" | "cloudOnly" | "machine";

/// Whether Auto's Cloud leg (the chevron and its list) shows: the key on and the plan active. An
/// unread plan is not active, so the chevron waits for the plan's answer rather than offering Cloud
/// to an account that has none.
export function autoCloudOn({ key, plan }: { key: boolean; plan: Pick<CloudPlanView, "state"> }): boolean {
  return key && plan.state === "active";
}

/// The Auto list's rows. Auto is offered only where Cloud is (App.tsx `autoOffered`), so the three
/// always show and each keeps its digit.
export const AUTO_PLACE_ROWS: readonly AutoPlaceRow[] = ["auto", "cloudOnly", "machine"];

/// The row ⌥⌘`digit` names in the Auto list (⌥⌘1 Auto, ⌥⌘2 Cloud only, ⌥⌘3 Machine…); none past the end.
export function autoPlaceForDigit(digit: number): AutoPlaceRow | undefined {
  return Number.isInteger(digit) && digit >= 1 ? AUTO_PLACE_ROWS[digit - 1] : undefined;
}

import type { useT } from "../i18n";
import { SINCE_COUNT_CAP } from "./sinceNews";

/// The count as the label shows it: "999+" past the cap.
export const shownCount = (count: number): number | string => (count > SINCE_COUNT_CAP ? `${SINCE_COUNT_CAP}+` : count);

/// "157 new messages", "999+ new messages" past the count's cap.
export function newMessagesLabel(t: ReturnType<typeof useT>, count: number): string {
  return t("since.messages", { n: shownCount(count) });
}

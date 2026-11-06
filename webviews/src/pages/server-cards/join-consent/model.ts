// What the join consent ask shows, from the host's status: who asked for what, the question, the
// note, why an Allow did not take, and whether Deny and Allow take a press now.
import type { Strings } from "../../shared/i18n";
import type { JoinConsentStatus } from "./types";

export interface JoinConsentView {
  title: string;
  question: string;
  note: string;
  error: string | null;
  /** Both buttons are off while a write is in flight. */
  enabled: boolean;
}

export function viewOf(status: JoinConsentStatus | undefined, { t, format }: Strings): JoinConsentView | null {
  const ask = status?.ask;
  if (!status || !ask) return null;
  const screen = ask.surface === "screen";
  return {
    title: format(screen ? "devices.join.ask.screen" : "devices.join.ask.control", ask.requester),
    question: t(screen ? "devices.join.ask.screenQuestion" : "devices.join.ask.controlQuestion"),
    note: t("devices.join.ask.note"),
    error: status.error,
    enabled: !status.writing,
  };
}

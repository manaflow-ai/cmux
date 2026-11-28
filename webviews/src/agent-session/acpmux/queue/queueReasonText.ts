import type { Translate } from "../i18n";
import { formatCost } from "../ledger/ledgerModel";
import type { QueueReason } from "./queueModel";

export function reasonText(reason: QueueReason, t: Translate): string {
  switch (reason.kind) {
    case "blocksTurn":
      return t("waiting.reason.blocksTurn");
    case "queuedPrompts":
      return t("waiting.reason.queuedPrompts", { n: reason.n });
    case "subsessions":
      return t("waiting.reason.subsessions", { n: reason.n });
    case "costUsd":
      return t("waiting.reason.costUsd", { cost: formatCost(reason.usd, document.documentElement.lang || undefined) });
    case "age":
      return t("waiting.reason.age");
  }
}

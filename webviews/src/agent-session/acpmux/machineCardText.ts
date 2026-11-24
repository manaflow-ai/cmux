import type { Translate } from "./i18n";
import type { MachineCardStatus } from "./machineCardModel";

/// The status's word: Awake and Asleep, as the person says it of a machine.
export function machineStatusWord(status: MachineCardStatus, t: Translate): string {
  switch (status) {
    case "awake":
      return t("machineCard.awake");
    case "paused":
      return t("machineCard.asleep");
    case "starting":
      return t("machineCard.waking");
    case "failed":
      return t("machineCard.failed");
  }
}

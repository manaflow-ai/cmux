import { Notice as UiNotice } from "../../../ui/Notice";
import { useT } from "../i18n";
import type { ComputerUseState } from "./computerUseState";

/// What the chat says above the composer when a send names `@computer-use` and Computer Use is not
/// ready (CMUX-682; Lucas, standup 2026-11-20: "computer use is not set up, and then they press set
/// up computer use"). The message stays in the composer. Set Up Computer Use opens the onboarding
/// step that turns it on and asks for both grants; the person sends again once it is done. Turned
/// off by the organization: no setup can help, so the notice only says so.
export function ComputerUseSetupNotice({
  state,
  onSetUp,
  onDismiss,
}: {
  state: Extract<ComputerUseState, "needs_setup" | "disabled" | "starting">;
  onSetUp(): void;
  onDismiss(): void;
}) {
  const t = useT();
  const disabled = state === "disabled";
  return (
    <UiNotice
      id="computer-use-setup"
      kind="warning"
      placement="banner"
      title={t(disabled ? "computerUseSetup.disabledTitle" : "computerUseSetup.title")}
      message={disabled ? undefined : t("computerUseSetup.detail")}
      actions={disabled ? [] : [{ id: "set-up", label: t("computerUseSetup.setUp"), primary: true, onSelect: onSetUp }]}
      onDismiss={onDismiss}
      dismissLabel={t("toast.dismiss")}
    />
  );
}

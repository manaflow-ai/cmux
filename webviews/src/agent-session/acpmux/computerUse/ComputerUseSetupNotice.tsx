import { Notice as UiNotice } from "../../../ui/Notice";
import { useT } from "../i18n";
import { computerUseHoldText, type ComputerUseHold } from "./computerUseState";

/// What the chat says above the composer when a send names `@computer-use` and Computer Use cannot
/// take it (CMUX-682; Lucas, standup 2026-11-20: "computer use is not set up, and then they press set
/// up computer use"). The message stays in the composer. Not set up: Set Up Computer Use opens the
/// onboarding step that turns it on and asks for both grants; the person sends again once it is done.
/// Turned off by the organization, a build without it, or a chat that does not run on this Mac
/// (#48541): no setup can help, so the notice only says why.
export function ComputerUseSetupNotice({
  hold,
  onSetUp,
  onDismiss,
}: {
  hold: ComputerUseHold;
  onSetUp(): void;
  onDismiss(): void;
}) {
  const t = useT();
  const text = computerUseHoldText(hold);
  return (
    <UiNotice
      id="computer-use-setup"
      kind="warning"
      placement="banner"
      title={t(text.title)}
      message={text.detail ? t(text.detail) : undefined}
      actions={
        hold === "setup" ? [{ id: "set-up", label: t("computerUseSetup.setUp"), primary: true, onSelect: onSetUp }] : []
      }
      onDismiss={onDismiss}
      dismissLabel={t("toast.dismiss")}
    />
  );
}

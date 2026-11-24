// Under a Computer Use call macOS refused for a missing permission: one line and Set Up Computer Use,
// which opens the app's step-by-step window (the same one as the command palette and Settings). It runs
// only on the person's click; the app refuses it without one.
import { useState } from "react";
import { Button } from "../../../ui/Button";
import { useT } from "../i18n";
import { postNative } from "../native";
import { COMPUTER_USE_SETUP_ACTION } from "./computerUseSetup";

export function ComputerUseSetupCard({
  request = postNative,
}: {
  request?: <T = unknown>(method: string, params?: Record<string, unknown>) => Promise<T>;
}) {
  const t = useT();
  const [opening, setOpening] = useState(false);
  return (
    <div className="cv-cu-setup" data-computer-use-setup="">
      <span>{t("computerUse.setup.needed")}</span>
      <Button
        type="button"
        size="sm"
        variant="solid"
        disabled={opening}
        data-action={COMPUTER_USE_SETUP_ACTION}
        onClick={() => {
          setOpening(true);
          void request("action.run", { id: COMPUTER_USE_SETUP_ACTION }).finally(() => setOpening(false));
        }}
      >
        {t("computerUse.setup.button")}
      </Button>
    </div>
  );
}

// l10n-allow-file: interactive gallery fixture, never shipped product copy.
import { useEffect, useState } from "react";
import { StartFailure } from "./newtab/StartFailure";
import { SwitchNotice } from "./SwitchNotice";
import { setStartRecoveryPreview } from "./startRecoveryPreview";

export function StartRecoveryScene({
  surface = "newtab",
  enabled = true,
  setupFails = false,
}: {
  surface?: "newtab" | "chat";
  enabled?: boolean;
  setupFails?: boolean;
}) {
  const [failed, setFailed] = useState(false);
  const [harness, setHarness] = useState("claude");
  const [outcome, setOutcome] = useState("");
  useEffect(() => {
    setStartRecoveryPreview(enabled);
    return () => setStartRecoveryPreview(false);
  }, [enabled]);
  const name = harness === "claude" ? "Claude Code" : "Codex";
  const error = `spawn ${harness} ENOENT`;
  const install = () => {
    setOutcome(setupFails ? "Setup failed; the draft and retry remain available." : `Install requested for ${name}`);
    if (!setupFails) setFailed(false);
  };
  return (
    <div>
      <textarea aria-label="Draft" defaultValue="Keep this prompt and its selected agent." />
      <button type="button" onClick={() => setFailed(true)}>
        Start
      </button>
      <button type="button" onClick={() => setHarness(harness === "claude" ? "codex" : "claude")}>
        Change selection
      </button>
      <output>{outcome}</output>
      {failed &&
        (surface === "newtab" ? (
          <StartFailure
            failure={{ harness, error, local: true, retry: () => setOutcome("Retry requested") }}
            name={name}
            onInstall={install}
            onDismiss={() => setFailed(false)}
          />
        ) : (
          <SwitchNotice
            switching={{ harness, name, phase: "failed", error }}
            onAction={install}
            onRetry={() => setOutcome("Retry requested")}
          />
        ))}
    </div>
  );
}

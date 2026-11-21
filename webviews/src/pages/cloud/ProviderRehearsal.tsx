import { useState } from "react";
import { experimentArm } from "../../experiments/experiment";
import type { Strings } from "../shared/i18n";
import { providerRehearsal } from "./providerRehearsal.experiment";
import type { CloudStore } from "./store";
import { L } from "./strings";

export type RehearsalScenario = "lifecycle" | "enrollment_failure" | "cleanup_failure";

export function ProviderRehearsal({ store, strings }: { store: CloudStore; strings: Strings }) {
  const arm = experimentArm(providerRehearsal);
  const [result, setResult] = useState<unknown>();
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const { t } = strings;
  if (arm === "off") return null;
  const run = async (scenario: RehearsalScenario) => {
    setBusy(true);
    setFailed(false);
    setResult(undefined);
    try {
      setResult(await store.rehearseProvider(scenario));
    } catch {
      setFailed(true);
    } finally {
      setBusy(false);
    }
  };
  return (
    <details className="cloud-provider-rehearsal" open={arm === "expanded"}>
      <summary>{t(L.rehearsalTitle)}</summary>
      <p>{t(L.rehearsalNote)}</p>
      <div className="cloud-provider-rehearsal-actions">
        {(
          [
            ["lifecycle", L.rehearsalLifecycle],
            ["enrollment_failure", L.rehearsalEnrollment],
            ["cleanup_failure", L.rehearsalCleanup],
          ] as const
        ).map(([scenario, label]) => (
          <button
            key={scenario}
            type="button"
            className="cloud-button"
            disabled={busy}
            onClick={() => void run(scenario)}
          >
            {t(label)}
          </button>
        ))}
      </div>
      {failed && <p role="alert">{t(L.actionFailed)}</p>}
      {result !== undefined && (
        <pre tabIndex={0} aria-label={t(L.rehearsalTitle)}>
          {JSON.stringify(result, null, 2)}
        </pre>
      )}
    </details>
  );
}

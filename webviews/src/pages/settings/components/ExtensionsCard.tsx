// Settings > Advanced > Extensions (extensions DESIGN.md section 14 step 2, "Meter in Settings";
// ledger row 642c6b1d4b). One row per installed extension with what the host's budget saw (`cmux apps meters`, the daemon's
// apps.meters) and, while safe mode is on, the bisect that finds the extension that breaks cmux
// (`cmux safe-mode bisect`, the daemon's safe_mode.bisect). The daemon owns both; this card draws
// their answers and sends the person's step. With no extension installed it draws nothing.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import type { ExtensionBisect, ExtensionMeter, ExtensionsVerb } from "../ops";
import { settingsKeys } from "../queries";
import type { SettingsStore } from "../store";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";

export const EXTENSIONS_KEY = [...settingsKeys.all, "extensions"] as const;

/** The meter rows and safe mode's state; null parts when the host has no CLI or no daemon. */
export type ExtensionsRead = { meters: ExtensionMeter[]; safeMode: { on: boolean; bisect?: ExtensionBisect } | null };

export async function readExtensions(store: SettingsStore): Promise<ExtensionsRead> {
  const [meters, status] = await Promise.all([store.extensions("meters"), store.extensions("status")]);
  const safe = status.answer;
  return {
    meters: meters.answer?.meters ?? [],
    safeMode: safe ? { on: safe.on === true, bisect: safe.bisect } : null,
  };
}

const HOSTS = new Set(["none", "starting", "running", "stopping", "restarting", "waiting"]);

/** One meter in words: "Paused (over its batch rate) · Running · 2 views · 40 batches, 9 held". */
export function meterLine(meter: ExtensionMeter): string {
  const step =
    meter.step === "paused" && meter.paused
      ? t("settingsPage.extensions.step.pausedWhy", meter.paused)
      : t(`settingsPage.extensions.step.${meter.step}`);
  const host = HOSTS.has(meter.host) ? t(`settingsPage.extensions.host.${meter.host}`) : meter.host;
  const parts = [step, host, t("settingsPage.extensions.views", String(meter.mounts))];
  parts.push(t("settingsPage.extensions.batches", String(meter.batches.in), String(meter.held)));
  if (meter.crashes > 0) parts.push(t("settingsPage.extensions.crashes", String(meter.crashes)));
  return parts.join(" · ");
}

/** The bisect in words, and the steps the person can take now. */
export function bisectState(bisect: ExtensionBisect | undefined): { text: string; steps: ExtensionsVerb[] } {
  if (!bisect) return { text: t("settingsPage.extensions.bisect.idle"), steps: ["start"] };
  if (bisect.found) return { text: t("settingsPage.extensions.bisect.found", bisect.found), steps: ["reset"] };
  return {
    text: t("settingsPage.extensions.bisect.running", bisect.running.join(", ") || "-", String(bisect.suspects.length)),
    steps: ["good", "bad", "reset"],
  };
}

export function ExtensionsCard() {
  const store = useStore();
  const queryClient = useQueryClient();
  const query = useQuery({ queryKey: EXTENSIONS_KEY, queryFn: () => readExtensions(store) });
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const read = query.data;
  if (!read || read.meters.length === 0) return null;
  const step = (verb: ExtensionsVerb) => {
    setBusy(true);
    setRefusal(null);
    void store
      .extensions(verb)
      .then(async (answer) => {
        setRefusal(answer.refusal);
        await queryClient.invalidateQueries({ queryKey: EXTENSIONS_KEY });
      })
      .finally(() => setBusy(false));
  };
  return <ExtensionsView read={read} busy={busy} refusal={refusal} onStep={step} />;
}

/** The card as it draws, from a read: the gallery draws it with fixtures. */
export function ExtensionsView({
  read,
  busy = false,
  refusal = null,
  onStep,
}: {
  read: ExtensionsRead;
  busy?: boolean;
  refusal?: string | null;
  onStep: (verb: ExtensionsVerb) => void;
}) {
  const bisect = read.safeMode?.on ? bisectState(read.safeMode.bisect) : null;
  return (
    <section className="group" data-card="extensions">
      <h3 className="group-title">{t("settingsPage.extensions.title")}</h3>
      <div className="rows">
        {read.meters.map((meter) => (
          <div key={meter.app} data-extension-meter={meter.app} data-step={meter.step}>
            <ActionRow title={meter.app} help={meterLine(meter)}>
              {null}
            </ActionRow>
          </div>
        ))}
        {bisect && (
          <div data-extension-bisect="">
            <ActionRow title={t("settingsPage.extensions.bisect.title")} help={refusal ?? bisect.text}>
              {bisect.steps.map((verb) => (
                <Button
                  key={verb}
                  type="button"
                  className="button"
                  data-bisect-step={verb}
                  disabled={busy}
                  onClick={() => onStep(verb)}
                >
                  {t(`settingsPage.extensions.bisect.${verb}`)}
                </Button>
              ))}
            </ActionRow>
          </div>
        )}
      </div>
    </section>
  );
}

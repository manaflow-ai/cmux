// The surge card's text. The Cloud app server computes the surge (first-party-apps/cloud/server/src/ops/surge.rs);
// this file only decides whether it still shows and formats it.
import { intl } from "../../ui/intl";
import type { CloudMachine, CloudSurge } from "./ops";
import { format, L } from "./strings";

/** The surge to show: none once every one of its machines left the page's mirror (a person deleted them). */
export function shownSurge(surge: CloudSurge | undefined, machines: readonly CloudMachine[]): CloudSurge | undefined {
  if (!surge || surge.count === 0) return undefined;
  const listed = new Set(machines.map((machine) => machine.id));
  return surge.machines.some((id) => listed.has(id)) ? surge : undefined;
}

/** Seconds, to the second: "33 s", "4 min 57 s". */
export function seconds(ms: number, language: string): string {
  const total = Math.max(1, Math.round(ms / 1000));
  const unit = (value: number, name: "minute" | "second") =>
    intl.NumberFormat(language, { style: "unit", unit: name, unitDisplay: "short" }).format(value);
  const minutes = Math.floor(total / 60);
  const rest = total % 60;
  if (minutes === 0) return unit(rest, "second");
  return rest === 0 ? unit(minutes, "minute") : `${unit(minutes, "minute")} ${unit(rest, "second")}`;
}

/** The card's facts in reading order: ready, time to the last one ready, then the queue. */
export function surgeParts(surge: CloudSurge, t: (key: string) => string, language: string): string[] {
  const parts = [format(t(L.surgeReady), { ready: surge.ready, count: surge.count })];
  if (surge.last_ready_ms !== undefined) {
    parts.push(format(t(L.surgeLastReady), { duration: seconds(surge.last_ready_ms, language) }));
  }
  parts.push(surge.drained ? t(L.surgeDrained) : format(t(L.surgeStarting), { count: surge.starting }));
  if (surge.failed > 0) parts.push(format(t(L.surgeFailed), { count: surge.failed }));
  return parts;
}

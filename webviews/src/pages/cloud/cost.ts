// A machine's cost in words, as the Mac sidebar says it (SidebarMachineCost+Text.swift):
// "$0.26/h · Running 2h 14m · About $0.58 so far"; while paused only "$0.26/h when running". Every
// number comes from the server (`hourly_rate_usd`, `running_since`); this only formats them.
import { useEffect, useState } from "react";
import type { CloudMachine } from "./ops";
import { format, L } from "./strings";

const MINUTE = 60_000;

/** US dollars to the cent ("$0.26"). */
function price(usd: number, language: string): string {
  return new Intl.NumberFormat(language, {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(usd);
}

/** Time running in at most two units ("2h 14m", "3d 4h"); under a minute reads as one. */
function duration(ms: number, language: string): string {
  const minutes = Math.floor(Math.max(MINUTE, ms) / MINUTE);
  const units: [Intl.NumberFormatOptions["unit"], number][] = [
    ["day", Math.floor(minutes / 1440)],
    ["hour", Math.floor(minutes / 60) % 24],
    ["minute", minutes % 60],
  ];
  const first = units.findIndex(([, value]) => value > 0);
  return units
    .slice(first, first + 2)
    .filter(([, value]) => value > 0)
    .map(([unit, value]) =>
      new Intl.NumberFormat(language, { style: "unit", unit, unitDisplay: "narrow" }).format(value),
    )
    .join(" ");
}

/** Milliseconds running at `now`, or undefined when the machine is not running or the server sent no start. */
function runningMs(machine: CloudMachine, now: number): number | undefined {
  if (machine.status !== "running" || typeof machine.running_since !== "number") return undefined;
  return Math.max(0, now - machine.running_since);
}

/** Whether the cost line changes with time: a running machine with a start time. */
export function costTicks(machine: CloudMachine | undefined): boolean {
  return !!machine && runningMs(machine, 0) !== undefined;
}

/**
 * Rate, time running and the estimate so far; while not running only the rate, "when running", so a
 * paused machine shows no running cost. Undefined without a rate or a running time.
 */
export function costLine(
  machine: CloudMachine,
  now: number,
  t: (key: string) => string,
  language: string,
): string | undefined {
  const rate = typeof machine.hourly_rate_usd === "number" ? machine.hourly_rate_usd : undefined;
  const ms = runningMs(machine, now);
  if (ms === undefined)
    return rate === undefined ? undefined : format(t(L.costRateWhenRunning), { price: price(rate, language) });
  const parts: string[] = [];
  if (rate !== undefined) parts.push(format(t(L.costRate), { price: price(rate, language) }));
  parts.push(format(t(L.costRunning), { duration: duration(ms, language) }));
  if (rate !== undefined) {
    const spent = (rate * ms) / 3_600_000;
    parts.push(
      spent < 0.01
        ? format(t(L.costUnderSoFar), { price: price(0.01, language) })
        : format(t(L.costSoFar), { price: price(spent, language) }),
    );
  }
  return parts.join(" · ");
}

/**
 * The time for cost lines: `Date.now()`, refreshed each minute while `ticking` (some shown machine is
 * running). The interval stops when nothing shown is running and on unmount.
 */
export function useCostClock(ticking: boolean): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!ticking) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), MINUTE);
    return () => clearInterval(timer);
  }, [ticking]);
  return now;
}

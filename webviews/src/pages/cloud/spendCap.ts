// The team's spending cap on Cloud machines, as the page shows it (cmux-platform SpendCap.ts, cmux#39915;
// cmuxterm-hq#8205). The backend decides every state: `cloud.plan.get`'s `spend_cap` (the team's last read and a
// pending or done pause), each machine's `paused_by` and `spend_cap_pause_at`, and the refusals
// `cloud.spend_cap.reached` and `cloud.member_budget.reached`. The page computes no cap; it words them, and every
// sentence names what the person can do (an admin raises the cap, or it resets on its date).
import type { CloudMachine, CloudPlan } from "./ops";
import { format, L } from "./strings";

type Translate = (key: string) => string;

/** `cloud.plan.get`'s `spend_cap`, absent from a server without the cap. */
export type SpendCap = NonNullable<CloudPlan["spend_cap"]>;

/** What the team-level banner says, or none (under the cap, never read, or no cap). */
export type CapBanner =
  | { kind: "near"; spent: number; cap: number; periodEnd?: number }
  | { kind: "pausing"; pauseAt: number; spent?: number; cap?: number; periodEnd?: number }
  | { kind: "paused"; spent?: number; cap?: number; periodEnd?: number }
  | { kind: "reached"; spent?: number; cap?: number; periodEnd?: number };

const num = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;

/** The banner of the team's cap. A pause that already happened outranks a pending one, which outranks the rest. */
export function capBanner(cap: SpendCap | null | undefined): CapBanner | undefined {
  if (!cap) return undefined;
  const spent = num(cap.spent_usd);
  const limit = num(cap.cap_usd);
  const periodEnd = num(cap.period_end);
  const amounts = {
    ...(spent !== undefined ? { spent } : {}),
    ...(limit !== undefined ? { cap: limit } : {}),
    ...(periodEnd !== undefined ? { periodEnd } : {}),
  };
  const pauseAt = num(cap.pause_at);
  if (num(cap.paused_at) !== undefined && cap.state === "at_cap") return { kind: "paused", ...amounts };
  if (pauseAt !== undefined) return { kind: "pausing", pauseAt, ...amounts };
  if (cap.state === "at_cap") return { kind: "reached", ...amounts };
  if (cap.state === "near" && spent !== undefined && limit !== undefined)
    return { kind: "near", spent, cap: limit, ...(periodEnd !== undefined ? { periodEnd } : {}) };
  return undefined;
}

export function usd(value: number, language: string): string {
  return new Intl.NumberFormat(language, { style: "currency", currency: "USD" }).format(value);
}

export function clockTime(ms: number, language: string): string {
  return new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" }).format(ms);
}

export function day(ms: number, language: string): string {
  return new Intl.DateTimeFormat(language, { dateStyle: "medium" }).format(ms);
}

/** "$51.20 of $50.00 spent this period.", or nothing when either amount is unknown. */
export function spentLine(spent: number | undefined, cap: number | undefined, t: Translate, language: string) {
  return spent === undefined || cap === undefined
    ? ""
    : format(t(L.capSpent), { spent: usd(spent, language), cap: usd(cap, language) });
}

/** What the person can do: an admin raises the cap, or it resets on the period's end. */
export function askLine(periodEnd: number | undefined, t: Translate, language: string): string {
  return periodEnd === undefined ? t(L.capAskAdmin) : format(t(L.capAsk), { date: day(periodEnd, language) });
}

const join = (...parts: string[]) => parts.filter(Boolean).join(" ");

/** The banner's title and line. */
export function capBannerText(banner: CapBanner, t: Translate, language: string): { title: string; message: string } {
  const spent = spentLine(banner.spent, banner.cap, t, language);
  const ask = askLine(banner.periodEnd, t, language);
  switch (banner.kind) {
    case "near":
      return { title: t(L.capNear), message: join(spent, t(L.capNearBody), ask) };
    case "pausing":
      return {
        title: t(L.capReached),
        message: join(format(t(L.capPausesAt), { time: clockTime(banner.pauseAt, language) }), ask),
      };
    case "paused":
      return { title: t(L.capPaused), message: join(spent, t(L.capPausedBody), ask) };
    case "reached":
      return { title: t(L.capReached), message: join(spent, t(L.capNoStarts), ask) };
  }
}

/**
 * A machine's own cap line for its row and detail: paused by the cap, or running with the cap's pause
 * pending. None otherwise (a start or a raised cap clears both marks on the record).
 */
export function machineCapNote(machine: CloudMachine | undefined, t: Translate, language: string) {
  if (!machine) return undefined;
  if (machine.status === "paused" && machine.paused_by === "spend_cap") return t(L.capMachinePaused);
  const pauseAt = num(machine.spend_cap_pause_at);
  if (machine.status === "running" && pauseAt !== undefined)
    return format(t(L.capMachinePausesAt), { time: clockTime(pauseAt, language) });
  return undefined;
}

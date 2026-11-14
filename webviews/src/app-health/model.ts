// What the health indicator and popover show, derived from one snapshot: whether anything shows at
// all, the worst part, its tone and its one line. Pure, so the gallery and tests read the same rules.
import type { Strings } from "../pages/shared/i18n";
import type { HealthPart, HealthSnapshot, HealthState } from "./types";

/** Worst first, as the contract orders them. */
const RANK: Record<HealthState, number> = { failed: 4, stuck: 3, repairing: 2, slow: 1, healthy: 0 };

/** The dot's color role: danger for a part that needs the person, attention while the app works on
 * it, muted for a queued action alone. */
export type HealthTone = "danger" | "attention" | "muted";

/** Nothing shows: every part is healthy and no action waits. */
export function isQuiet(snapshot: HealthSnapshot | null | undefined): boolean {
  return !snapshot || ((snapshot.worst === "healthy" || snapshot.parts.length === 0) && !snapshot.pending?.length);
}

/** The part the line names: the worst state, the longest in it first. */
export function worstPart(snapshot: HealthSnapshot): HealthPart | null {
  let worst: HealthPart | null = null;
  for (const part of snapshot.parts) {
    if (part.state === "healthy") continue;
    if (!worst || RANK[part.state] > RANK[worst.state] || (part.state === worst.state && part.sinceMs < worst.sinceMs))
      worst = part;
  }
  return worst;
}

/** Every other non-healthy part, worst first. */
export function otherParts(snapshot: HealthSnapshot, worst: HealthPart | null): HealthPart[] {
  return snapshot.parts
    .filter((part) => part !== worst && part.state !== "healthy")
    .sort((a, b) => RANK[b.state] - RANK[a.state] || a.sinceMs - b.sinceMs);
}

export function toneOf(state: HealthState | null): HealthTone {
  if (state === "failed" || state === "stuck") return "danger";
  if (state === "repairing" || state === "slow") return "attention";
  return "muted";
}

/** A queued action's line: "Reconnecting; will close Background task when back". */
export function pendingLine(label: string, strings: Strings): string {
  return strings.format("appHealth.pending", label);
}

/** The indicator's dot and one line, or null when it is quiet. */
export function headline(
  snapshot: HealthSnapshot | null | undefined,
  strings: Strings,
): { tone: HealthTone; text: string; part: HealthPart | null } | null {
  if (!snapshot || isQuiet(snapshot)) return null;
  const part = worstPart(snapshot);
  if (part)
    return {
      tone: toneOf(part.state),
      text: strings.format("appHealth.line", part.label, strings.t(`appHealth.state.${part.state}`)),
      part,
    };
  const pending = snapshot.pending?.[0];
  return pending ? { tone: "muted", text: pendingLine(pending.label, strings), part: null } : null;
}

/** The indicator's line for one part: what is wrong with it, in a sentence the person can act on ("Agent
 * chat isn't responding": the click opens Repair now; "Repairing Agent chat…": the app is on it). Null for
 * a part that is only slow or healthy: it still answers, and if it stops the model makes it stuck and
 * repairs it, so a "Slow" line named nothing the person could do (Leo, 2026-11-11: "slow indicator on the
 * bottom left is uselsss"). */
export function indicatorLine(part: HealthPart, strings: Strings): string | null {
  switch (part.state) {
    case "stuck":
      return strings.format("appHealth.line.stuck", part.label);
    case "repairing":
      return strings.format("appHealth.line.repairing", part.label);
    case "failed":
      return strings.format("appHealth.line.failed", part.label);
    default:
      return null;
  }
}

/** What the sidebar's indicator shows, or null: the worst part past slow, else the newest queued action.
 * The native footer line says the same (AppHealthStrings.line, AppHealth.headline(of:)). */
export function indicatorHeadline(
  snapshot: HealthSnapshot | null | undefined,
  strings: Strings,
): { tone: HealthTone; text: string; part: HealthPart | null } | null {
  if (!snapshot || isQuiet(snapshot)) return null;
  const part = worstPart({ ...snapshot, parts: snapshot.parts.filter((each) => RANK[each.state] > RANK.slow) });
  const text = part && indicatorLine(part, strings);
  if (part && text) return { tone: toneOf(part.state), text, part };
  const pending = snapshot.pending?.[0];
  return pending ? { tone: "muted", text: pendingLine(pending.label, strings), part: null } : null;
}

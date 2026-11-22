// Changes' Fix failing checks button (fixChecks.experiment.ts, FixChecksButton.tsx): what it counts and
// what it says it sends. The classifier is acpmux's (`_acpmux/pr_feedback`, pr_feedback/classify.rs):
// the row's own count is `failing` less `failingOnBase`, and the names come from acpmux's answer.

/// The reds the button counts: the row's failing checks less those failing on base too; -1 when
/// the row says failing with no count (the button then names no number).
export function ownFailing(failing: number, onBase: number): number {
  if (failing === -1) return -1;
  return Math.max(0, failing - Math.max(0, onBase));
}

/// One red the message sends.
export type FixCheck = { name: string; url?: string; step?: string };

/// acpmux's checks answer, as the button shows it: the message, the reds it sends, the base reds it
/// leaves out. Undefined for an answer that is not one (an older acpmux, a failure).
export type FixChecksPreview = { draft: string; empty: boolean; own: FixCheck[]; onBase: string[] };

const text = (value: unknown): string | undefined => (typeof value === "string" && value.trim() ? value : undefined);

export function fixChecksPreview(answer: unknown): FixChecksPreview | undefined {
  if (!answer || typeof answer !== "object") return undefined;
  const { draft, empty, checks } = answer as { draft?: unknown; empty?: unknown; checks?: unknown };
  const body = text(draft);
  if (!body) return undefined;
  const detail = (checks && typeof checks === "object" ? checks : {}) as { own?: unknown; onBase?: unknown };
  const own: FixCheck[] = [];
  for (const red of Array.isArray(detail.own) ? detail.own : []) {
    if (!red || typeof red !== "object") continue;
    const { name, url, step } = red as { name?: unknown; url?: unknown; step?: unknown };
    const named = text(name);
    if (!named) continue;
    const link = text(url);
    const failed = text(step);
    own.push({ name: named, ...(link ? { url: link } : {}), ...(failed ? { step: failed } : {}) });
  }
  const onBase = (Array.isArray(detail.onBase) ? detail.onBase : []).map(text).filter((n): n is string => !!n);
  return { draft: body, empty: empty === true, own, onBase };
}

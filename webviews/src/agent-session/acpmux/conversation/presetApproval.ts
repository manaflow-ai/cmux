// A no-prompt preset's approval card (acpmux `hub/unattended_presets.rs`; Leo, 2026-11-09: "A
// no-prompt preset approved once in the cmux app would let those sessions run without anyone
// watching." "yeah we should have that too"). When an agent in this chat starts a chat on another
// machine from a preset whose policy does not ask, and the person has not approved that preset,
// acpmux refuses the start and appends a `preset_approval_request` record to this chat. The card
// (PresetApprovalCard.tsx) answers with `_acpmux/presets {name, approveMode, approveDigest,
// sessionId}`; acpmux then appends `preset_approval_decision {preset, digest, outcome}`, which
// closes every card for that preset and digest shown before it.
//
// This module is the card's state, derived once per record (direct.ts), never per token. An agent
// that tries again before the person answers appends another request for the same preset and
// digest: it joins the card already open, so the chat shows one card per question. A request after
// a decision is a new question and draws a new card. Which records close which card goes by record
// seq, so an older page read later settles it the same way.

/// The row kind that draws a preset approval card (rows/registry.tsx).
export const PRESET_APPROVAL = "presetApproval";

/// What a `preset_approval_request` names: the preset, the digest of the contents the person is
/// asked about, and what the preset starts.
export type PresetApprovalAsk = {
  preset: string;
  digest: string;
  harness: string;
  policy: string;
  model?: string;
  effort?: string;
  /// The machine the agent tried to start a chat on.
  host?: string;
  description?: string;
};

export type PresetApprovalOutcome = "approved" | "declined";

/// A card's state on its row.
export type PresetApproval = {
  ask: PresetApprovalAsk;
  /// Set once a decision for its preset and digest came after it (or the person's own answer was
  /// accepted): the card is closed.
  outcome?: PresetApprovalOutcome;
  /// The answer on its way (client only): both buttons wait.
  busy?: PresetApprovalOutcome;
  /// The daemon's message for the last answer it refused (client only); the card stays open.
  error?: string;
};

const text = (value: unknown): string | undefined => {
  if (typeof value === "string") return value.trim() || undefined;
  // A policy acpmux writes as a value of its own (an object) still reads as one line.
  if (value !== null && value !== undefined && typeof value !== "object") return String(value);
  if (value && typeof value === "object") return JSON.stringify(value);
  return undefined;
};

/// The ask a `preset_approval_request` record's data names, or undefined for one the card cannot
/// draw or answer (no preset, digest, harness or policy).
export function presetApprovalAsk(data: unknown): PresetApprovalAsk | undefined {
  if (!data || typeof data !== "object") return undefined;
  const record = data as Record<string, unknown>;
  const preset = text(record.preset);
  const digest = text(record.digest);
  const harness = text(record.harness);
  const policy = text(record.policy);
  if (!preset || !digest || !harness || !policy) return undefined;
  const optional = (key: "model" | "effort" | "host" | "description") => {
    const value = typeof record[key] === "string" ? (record[key] as string).trim() : "";
    return value ? { [key]: value } : {};
  };
  return {
    preset,
    digest,
    harness,
    policy,
    ...optional("model"),
    ...optional("effort"),
    ...optional("host"),
    ...optional("description"),
  };
}

/// A `preset_approval_decision` record's data, or undefined for one that names no preset, no
/// digest or no outcome the card knows.
export function presetApprovalDecision(
  data: unknown,
): { preset: string; digest: string; outcome: PresetApprovalOutcome } | undefined {
  if (!data || typeof data !== "object") return undefined;
  const record = data as Record<string, unknown>;
  const preset = text(record.preset);
  const digest = text(record.digest);
  const outcome = record.outcome === "approved" || record.outcome === "declined" ? record.outcome : undefined;
  return preset && digest && outcome ? { preset, digest, outcome } : undefined;
}

const keyOf = (ask: { preset: string; digest: string }) => JSON.stringify([ask.preset, ask.digest]);

/// One chat's approval cards, folded from its records in any order. Rows are by id; a card's
/// first and last request seqs bound it, and the first decision of its key after them closes it.
export class PresetApprovalFold {
  private readonly cards = new Map<string, { key: string; first: number; last: number }>();
  private readonly decisions = new Map<string, { seq: number; outcome: PresetApprovalOutcome }[]>();

  clear(): void {
    this.cards.clear();
    this.decisions.clear();
  }

  /// A request record at `seq`: the row it draws in and that row's outcome. It joins its key's card
  /// when no decision of that key lies between them; else it opens a new card.
  request(seq: number, ask: PresetApprovalAsk): { rowId: string; outcome?: PresetApprovalOutcome } {
    const key = keyOf(ask);
    const decided = this.decisions.get(key) ?? [];
    let joined: string | undefined;
    for (const [id, card] of this.cards) {
      if (card.key !== key) continue;
      const low = Math.min(card.first, seq);
      const high = Math.max(card.last, seq);
      if (!decided.some((decision) => decision.seq > low && decision.seq < high)) joined = id;
    }
    const rowId = joined ?? `preset-approval-${seq}`;
    const card = this.cards.get(rowId);
    this.cards.set(
      rowId,
      card ? { key, first: Math.min(card.first, seq), last: Math.max(card.last, seq) } : { key, first: seq, last: seq },
    );
    return { rowId, outcome: this.outcome(rowId) };
  }

  /// A decision record at `seq`: the cards it closes now, with the outcome each gets.
  decide(
    seq: number,
    decision: { preset: string; digest: string; outcome: PresetApprovalOutcome },
  ): { rowId: string; outcome: PresetApprovalOutcome }[] {
    const key = keyOf(decision);
    const decided = this.decisions.get(key) ?? [];
    if (decided.some((each) => each.seq === seq)) return [];
    const before = new Map([...this.cards.keys()].map((id) => [id, this.outcome(id)]));
    this.decisions.set(
      key,
      [...decided, { seq, outcome: decision.outcome }].sort((a, b) => a.seq - b.seq),
    );
    const closed: { rowId: string; outcome: PresetApprovalOutcome }[] = [];
    for (const [id, card] of this.cards) {
      if (card.key !== key) continue;
      const outcome = this.outcome(id);
      if (outcome && outcome !== before.get(id)) closed.push({ rowId: id, outcome });
    }
    return closed;
  }

  /// A card's outcome: the first decision of its key after its last request, if one came.
  outcome(rowId: string): PresetApprovalOutcome | undefined {
    const card = this.cards.get(rowId);
    if (!card) return undefined;
    return this.decisions.get(card.key)?.find((decision) => decision.seq > card.last)?.outcome;
  }
}

/// The card after the person pressed Approve or Not now: both buttons wait, the last error goes.
export const presetApprovalSending = (approval: PresetApproval, answer: PresetApprovalOutcome): PresetApproval => ({
  ...approval,
  busy: answer,
  error: undefined,
});

/// The card after acpmux refused the answer: open again, with its message.
export const presetApprovalFailed = (approval: PresetApproval, message: string): PresetApproval => ({
  ...approval,
  busy: undefined,
  error: message || undefined,
});

/// The card closed with `outcome` (its decision record, or the person's answer accepted).
export const presetApprovalClosed = (approval: PresetApproval, outcome: PresetApprovalOutcome): PresetApproval => ({
  ask: approval.ask,
  outcome,
});

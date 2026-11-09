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

/// A card as the fold draws it now: its row, the newest request's ask, when its first request came
/// and its outcome.
export type PresetApprovalCardState = {
  rowId: string;
  ask: PresetApprovalAsk;
  at: number;
  outcome?: PresetApprovalOutcome;
};

/// What one record changed for its preset and digest: the rows that no longer stand for a card
/// (two cards joined, or one split, by a record read late) and every card of that key now.
export type PresetApprovalChange = { removed: string[]; cards: PresetApprovalCardState[] };

/// One chat's approval cards, folded from their records in any order. A key's requests in seq order
/// make one card until a decision of that key lies between two of them; the first decision after a
/// card's last request closes it. Each record recomputes its key's cards from every record held, so
/// a record read late (an older page) joins or splits cards the same way as in order. A card's row
/// is named by its first request's seq.
export class PresetApprovalFold {
  private readonly requests = new Map<string, { seq: number; at: number; ask: PresetApprovalAsk }[]>();
  private readonly decisions = new Map<string, { seq: number; outcome: PresetApprovalOutcome }[]>();
  /// The rows last reported for each key, and every card by row.
  private readonly shown = new Map<string, string[]>();
  private readonly cards = new Map<string, PresetApprovalCardState>();

  clear(): void {
    this.requests.clear();
    this.decisions.clear();
    this.shown.clear();
    this.cards.clear();
  }

  /// A request record at `seq` (its time `at`).
  request(seq: number, at: number, ask: PresetApprovalAsk): PresetApprovalChange {
    const key = keyOf(ask);
    const held = this.requests.get(key) ?? [];
    const kept = held.filter((each) => each.seq !== seq);
    this.requests.set(
      key,
      [...kept, { seq, at, ask }].sort((a, b) => a.seq - b.seq),
    );
    return this.reconcile(key);
  }

  /// A decision record at `seq`.
  decide(
    seq: number,
    decision: { preset: string; digest: string; outcome: PresetApprovalOutcome },
  ): PresetApprovalChange {
    const key = keyOf(decision);
    const held = this.decisions.get(key) ?? [];
    if (held.some((each) => each.seq === seq)) return { removed: [], cards: this.cardsOf(key) };
    this.decisions.set(
      key,
      [...held, { seq, outcome: decision.outcome }].sort((a, b) => a.seq - b.seq),
    );
    return this.reconcile(key);
  }

  /// A card's outcome, by its row.
  outcome(rowId: string): PresetApprovalOutcome | undefined {
    return this.cards.get(rowId)?.outcome;
  }

  private cardsOf(key: string): PresetApprovalCardState[] {
    return (this.shown.get(key) ?? []).flatMap((id) => this.cards.get(id) ?? []);
  }

  private reconcile(key: string): PresetApprovalChange {
    const requests = this.requests.get(key) ?? [];
    const decided = this.decisions.get(key) ?? [];
    const groups: (typeof requests)[] = [];
    for (const request of requests) {
      const group = groups.at(-1);
      const last = group?.at(-1);
      if (group && last && !decided.some((decision) => decision.seq > last.seq && decision.seq < request.seq))
        group.push(request);
      else groups.push([request]);
    }
    const cards = groups.map((group): PresetApprovalCardState => {
      const last = group.at(-1)!;
      const outcome = decided.find((decision) => decision.seq > last.seq)?.outcome;
      return {
        rowId: `preset-approval-${group[0].seq}`,
        ask: last.ask,
        at: group[0].at,
        ...(outcome ? { outcome } : {}),
      };
    });
    const ids = new Set(cards.map((card) => card.rowId));
    const removed = (this.shown.get(key) ?? []).filter((id) => !ids.has(id));
    for (const id of removed) this.cards.delete(id);
    for (const card of cards) this.cards.set(card.rowId, card);
    this.shown.set(key, [...ids]);
    return { removed, cards };
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

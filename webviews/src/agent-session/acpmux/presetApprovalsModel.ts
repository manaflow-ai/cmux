// The new chat home's "Unattended runs" card (PresetApprovals.tsx) reads acpmux's preset approvals
// (`_acpmux/preset_approvals`) and approves or revokes one (`_acpmux/preset_approve`). Leo,
// 2026-11-09, on a no-prompt preset approved once in the cmux app so handed-off fleet lanes run
// without anyone watching: "yeah we should have that too". This file reads the replies; the card
// draws them.
import type { StringKey } from "./i18n";

/// Who approved a preset, in the cmux app on which Mac, and when (ms epoch).
export type PresetApproval = { by: string; host: string; at: number };
/// A session started under the approval: the newest one.
export type PresetRun = { at: number; host?: string; sessionId?: string; from?: string };
/// An unapproved try: a coordinator dispatched with `-p NAME` to a fleet machine.
export type PresetAsk = { at: number; host?: string; from?: string };

export type PresetRow = {
  name: string;
  harness: string;
  model?: string;
  effort?: string;
  /// Always wider than ask: approve-reads, approve-edits, approve-all or review.
  policy: string;
  description?: string;
  /// The sha256 of the preset's contents the card shows; an approve sends it back.
  digest: string;
  /// Why it cannot be approved (`preset.env`, `preset.args`, `preset.mode`, `preset.system_prompt`).
  blocked?: string;
  approval?: PresetApproval;
  runs: number;
  lastRun?: PresetRun;
  /// Newest first, at most five.
  asks: PresetAsk[];
};

export type PresetApprovals = {
  presets: PresetRow[];
  /// The fleet agent machines an approved preset runs on (never a person's Mac).
  machines: string[];
};

/// The reads and the one write the card makes, on the pane's acpmux connection (direct.ts).
export type PresetApprovalsClient = {
  presetApprovals(): Promise<unknown>;
  /// Sent straight from the click: the host takes it only on the person's fresh gesture.
  presetApprove(name: string, approve: boolean, digest?: string): Promise<unknown>;
};

export const NO_PRESET_APPROVALS: PresetApprovals = { presets: [], machines: [] };

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value : undefined;
const time = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;
const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;

function approval(value: unknown): PresetApproval | undefined {
  const raw = record(value);
  const by = text(raw?.by);
  const host = text(raw?.host);
  const at = time(raw?.at);
  return by && host && at !== undefined ? { by, host, at } : undefined;
}

function sighting<T extends PresetAsk | PresetRun>(value: unknown): T | undefined {
  const raw = record(value);
  const at = time(raw?.at);
  if (at === undefined) return undefined;
  const host = text(raw?.host);
  const from = text(raw?.from);
  const sessionId = text(raw?.sessionId);
  return { at, ...(host ? { host } : {}), ...(from ? { from } : {}), ...(sessionId ? { sessionId } : {}) } as T;
}

/// One preset row of either reply, or undefined when it lacks what the card needs.
export function presetRow(value: unknown): PresetRow | undefined {
  const raw = record(value);
  const name = text(raw?.name);
  const harness = text(raw?.harness);
  const policy = text(raw?.policy);
  const digest = text(raw?.digest);
  if (!raw || !name || !harness || !policy || !digest) return undefined;
  const model = text(raw.model);
  const effort = text(raw.effort);
  const description = text(raw.description);
  const blocked = text(raw.blocked);
  const approved = approval(raw.approval);
  const lastRun = sighting<PresetRun>(raw.lastRun);
  const runs = time(raw.runs);
  return {
    name,
    harness,
    ...(model ? { model } : {}),
    ...(effort ? { effort } : {}),
    policy,
    ...(description ? { description } : {}),
    digest,
    ...(blocked ? { blocked } : {}),
    ...(approved ? { approval: approved } : {}),
    runs: runs !== undefined && runs > 0 ? Math.floor(runs) : 0,
    ...(lastRun ? { lastRun } : {}),
    asks: (Array.isArray(raw.asks) ? raw.asks : [])
      .map((ask) => sighting<PresetAsk>(ask))
      .filter((ask): ask is PresetAsk => ask !== undefined)
      .sort((left, right) => right.at - left.at)
      .slice(0, 5),
  };
}

/// The `_acpmux/preset_approvals` reply; anything malformed reads as no presets.
export function presetApprovals(value: unknown): PresetApprovals {
  const raw = record(value);
  const presets = (Array.isArray(raw?.presets) ? raw.presets : [])
    .map(presetRow)
    .filter((row): row is PresetRow => row !== undefined);
  const machines = (Array.isArray(raw?.machines) ? raw.machines : []).filter(
    (machine): machine is string => typeof machine === "string" && machine.trim() !== "",
  );
  return presets.length ? { presets, machines } : NO_PRESET_APPROVALS;
}

/// The row with `row` replacing the one of its name (an approve or revoke's reply).
export function withRow(list: PresetApprovals, row: PresetRow): PresetApprovals {
  return { ...list, presets: list.presets.map((entry) => (entry.name === row.name ? row : entry)) };
}

/// JSON-RPC's method-not-found: an acpmux that predates preset approvals.
export const METHOD_NOT_FOUND = -32601;

/// Whether `error` says the daemon has no such method (the card then draws nothing).
export function methodMissing(error: unknown): boolean {
  const raw = record(error);
  const data = record(raw?.data);
  return raw?.code === METHOD_NOT_FOUND || data?.code === METHOD_NOT_FOUND;
}

/// The reason acpmux gave for refusing an approve or revoke (`error.data.reason`).
export function refusalReason(error: unknown): string | undefined {
  const raw = record(error);
  return text(raw?.reason) ?? text(record(raw?.data)?.reason);
}

/// What a row is in: waiting on the person, approved, or one that cannot be approved.
export type PresetState = "needs" | "approved" | "blocked";
export function presetState(row: PresetRow): PresetState {
  if (row.approval) return "approved";
  return row.blocked ? "blocked" : "needs";
}

/// The policy in words, as what the lane does.
export const POLICY_WORDS: Record<string, StringKey> = {
  "approve-reads": "presetApprovals.policy.approveReads",
  "approve-edits": "presetApprovals.policy.approveEdits",
  "approve-all": "presetApprovals.policy.approveAll",
  review: "presetApprovals.policy.review",
};
export const POLICY_OTHER: StringKey = "presetApprovals.policy.other";

/// The approve confirm's first sentence: what lanes started with it will do without asking.
export const CONFIRM_WORDS: Record<string, StringKey> = {
  "approve-reads": "presetApprovals.confirm.approveReads",
  "approve-edits": "presetApprovals.confirm.approveEdits",
  "approve-all": "presetApprovals.confirm.approveAll",
  review: "presetApprovals.confirm.review",
};
export const CONFIRM_OTHER: StringKey = "presetApprovals.confirm.other";

/// Why a preset cannot be approved, by acpmux's reason code.
export const BLOCKED_WORDS: Record<string, StringKey> = {
  "preset.env": "presetApprovals.blocked.env",
  "preset.args": "presetApprovals.blocked.args",
  "preset.mode": "presetApprovals.blocked.mode",
  "preset.system_prompt": "presetApprovals.blocked.systemPrompt",
};
export const BLOCKED_OTHER: StringKey = "presetApprovals.blocked.other";

/// An approve or revoke's refusal in words, by `error.data.reason`.
export const ERROR_WORDS: Record<string, StringKey> = {
  "preset_approval.changed": "presetApprovals.error.changed",
  "permission.person_required": "presetApprovals.error.personRequired",
  "preset_approval.blocked": "presetApprovals.error.blocked",
  "preset_approval.no_preset": "presetApprovals.error.noPreset",
};
export const ERROR_OTHER: StringKey = "presetApprovals.error.other";

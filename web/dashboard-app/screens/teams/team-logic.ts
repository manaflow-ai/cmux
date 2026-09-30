import { MAX_INVITE_EMAILS, MAX_INVITE_LINK_USES } from "@/services/teams/limits";

/**
 * Pure rules shared by the team pages. Kept free of React and fetch so the
 * behavior is testable without rendering.
 */

export const TEAM_NAME_MAX_LENGTH = 120;
export { MAX_INVITE_EMAILS, MAX_INVITE_LINK_USES };

export type TeamNameValidation =
  | { readonly ok: true; readonly value: string }
  | { readonly ok: false; readonly reason: "empty" | "tooLong" };

export function validateTeamName(raw: string): TeamNameValidation {
  const value = raw.trim();
  if (value.length === 0) return { ok: false, reason: "empty" };
  if (value.length > TEAM_NAME_MAX_LENGTH) return { ok: false, reason: "tooLong" };
  return { ok: true, value };
}

// Deliberately permissive: the server and Stack own real validation. This
// only catches typos such as a missing domain before the request is sent.
const EMAIL_PATTERN = /^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$/;

export function isValidEmail(value: string): boolean {
  return value.length <= 254 && EMAIL_PATTERN.test(value);
}

export type EmailChip = { readonly email: string; readonly valid: boolean };

export type EmailChipUpdate = {
  readonly chips: readonly EmailChip[];
  /** Addresses dropped because the list already holds MAX_INVITE_EMAILS. */
  readonly overflow: number;
};

/** Split pasted text on commas, semicolons, spaces, and newlines. */
export function splitEmailInput(raw: string): string[] {
  return raw
    .split(/[\s,;]+/)
    .map((token) => token.trim().replace(/^<|>$/g, ""))
    .filter((token) => token.length > 0);
}

/**
 * Add pasted or typed addresses to the chip list. Duplicates are ignored
 * case-insensitively, invalid addresses stay visible so the user can fix
 * them, and anything past the cap is reported instead of silently dropped.
 */
export function addEmailChips(existing: readonly EmailChip[], raw: string): EmailChipUpdate {
  const chips = [...existing];
  const seen = new Set(existing.map((chip) => chip.email.toLowerCase()));
  let overflow = 0;
  for (const email of splitEmailInput(raw)) {
    const key = email.toLowerCase();
    if (seen.has(key)) continue;
    if (chips.length >= MAX_INVITE_EMAILS) {
      overflow += 1;
      continue;
    }
    seen.add(key);
    chips.push({ email, valid: isValidEmail(email) });
  }
  return { chips, overflow };
}

export function removeEmailChip(chips: readonly EmailChip[], email: string): EmailChip[] {
  return chips.filter((chip) => chip.email !== email);
}

/** The addresses to send, or null when any chip is invalid or none exist. */
export function sendableEmails(chips: readonly EmailChip[]): string[] | null {
  if (chips.length === 0 || chips.some((chip) => !chip.valid)) return null;
  return chips.map((chip) => chip.email);
}

export type SeatUsage = {
  readonly seats: number;
  readonly used: number;
  readonly over: number;
};

/**
 * Seats are soft. Returns the overage when members plus pending invitations
 * exceed the paid seat count, else null. Unlimited or unpaid teams (`seats`
 * null) never nudge.
 */
export function seatOverage(input: {
  readonly seats: number | null;
  readonly memberCount: number;
  readonly pendingInvitations: number;
}): SeatUsage | null {
  if (input.seats === null) return null;
  const used = input.memberCount + input.pendingInvitations;
  if (used <= input.seats) return null;
  return { seats: input.seats, used, over: used - input.seats };
}

export const INVITE_LINK_EXPIRY_OPTIONS = ["1", "7", "30", "never"] as const;
export type InviteLinkExpiryOption = (typeof INVITE_LINK_EXPIRY_OPTIONS)[number];

export function expiresInDays(option: InviteLinkExpiryOption): 1 | 7 | 30 | null {
  switch (option) {
    case "1":
      return 1;
    case "7":
      return 7;
    case "30":
      return 30;
    default:
      return null;
  }
}

/** Parse the optional max-uses field. Empty is unlimited; invalid is an error. */
export function parseMaxUses(raw: string): { ok: true; value: number | null } | { ok: false } {
  const value = raw.trim();
  if (value === "") return { ok: true, value: null };
  if (!/^\d+$/.test(value)) return { ok: false };
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > MAX_INVITE_LINK_USES) return { ok: false };
  return { ok: true, value: parsed };
}

export const KNOWN_PLAN_IDS = ["free", "go", "pro", "max", "team"] as const;
export type KnownPlanId = (typeof KNOWN_PLAN_IDS)[number];

/** Plan ids the UI has a label for. Unknown or missing ids read as Free. */
export function planLabelKey(planId: string | null | undefined): KnownPlanId {
  return (KNOWN_PLAN_IDS as readonly string[]).includes(planId ?? "")
    ? (planId as KnownPlanId)
    : "free";
}

export function teamCheckoutHref(teamId: string): string {
  const params = new URLSearchParams({ plan: "team", teamId });
  return `/api/billing/checkout?${params.toString()}`;
}

/** Initials for an avatar fallback, from the first two words of a name. */
export function initialsFor(name: string | null | undefined): string {
  const words = (name ?? "").trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return "?";
  return words
    .slice(0, 2)
    .map((word) => Array.from(word)[0]?.toUpperCase() ?? "")
    .join("");
}

import { strictEmailSchema } from "@hexclave/shared/dist/schema-fields";

/** The contact-channel fields the settings rules read. */
export type EmailChannelFacts = {
  readonly id: string;
  readonly value: string;
  readonly type: "email";
  readonly isPrimary: boolean;
  readonly isVerified: boolean;
  readonly usedForAuth: boolean;
};

/** Email rows, primary first, then verified, otherwise in server order. */
export function sortEmailChannels<T extends EmailChannelFacts>(channels: readonly T[]): T[] {
  return channels
    .filter((channel) => channel.type === "email")
    .map((channel, index) => ({ channel, index }))
    .sort((a, b) => {
      if (a.channel.isPrimary !== b.channel.isPrimary) return a.channel.isPrimary ? -1 : 1;
      if (a.channel.isVerified !== b.channel.isVerified) return a.channel.isVerified ? -1 : 1;
      return a.index - b.index;
    })
    .map(({ channel }) => channel);
}

/** True when exactly one email is used for sign-in (Hexclave's rule). */
export function isLastSignInEmail(channels: readonly EmailChannelFacts[]): boolean {
  return channels.filter((channel) => channel.type === "email" && channel.usedForAuth).length === 1;
}

/** At least one email used for sign-in; required to set a password. */
export function hasSignInEmail(channels: readonly EmailChannelFacts[]): boolean {
  return channels.some((channel) => channel.type === "email" && channel.usedForAuth);
}

/** At least one verified sign-in email; required for OTP and passkeys. */
export function hasVerifiedSignInEmail(channels: readonly EmailChannelFacts[]): boolean {
  return channels.some(
    (channel) => channel.type === "email" && channel.usedForAuth && channel.isVerified,
  );
}

export type EmailRowActionKind =
  | "sendVerification"
  | "setPrimary"
  | "useForSignIn"
  | "stopUsingForSignIn"
  | "remove";

export type EmailRowAction = {
  readonly kind: EmailRowActionKind;
  /** Present when the action is shown but disabled. */
  readonly disabledReason?: "verifyFirst" | "lastSignInEmail";
};

/**
 * The per-row actions, in menu order, with Hexclave's enablement rules:
 * send verification for unverified rows; set primary only when verified;
 * use for sign-in only when verified; never stop using or remove the last
 * sign-in email.
 */
export function emailRowActions(
  channel: EmailChannelFacts,
  lastSignInEmail: boolean,
): EmailRowAction[] {
  const actions: EmailRowAction[] = [];
  const isLastAuth = lastSignInEmail && channel.usedForAuth;
  if (!channel.isVerified) actions.push({ kind: "sendVerification" });
  if (!channel.isPrimary) {
    actions.push(
      channel.isVerified ? { kind: "setPrimary" } : { kind: "setPrimary", disabledReason: "verifyFirst" },
    );
  }
  if (!channel.usedForAuth && channel.isVerified) actions.push({ kind: "useForSignIn" });
  if (channel.usedForAuth) {
    actions.push(
      isLastAuth
        ? { kind: "stopUsingForSignIn", disabledReason: "lastSignInEmail" }
        : { kind: "stopUsingForSignIn" },
    );
  }
  actions.push(isLastAuth ? { kind: "remove", disabledReason: "lastSignInEmail" } : { kind: "remove" });
  return actions;
}

export type NewEmailError = "required" | "invalid" | "duplicate";

const strictEmail = strictEmailSchema(undefined);

/**
 * Validate an email before `createContactChannel`, using Hexclave's strict
 * email schema. Duplicates are compared case-insensitively.
 */
export function validateNewEmail(
  value: string,
  existing: readonly Pick<EmailChannelFacts, "value">[],
): NewEmailError | null {
  const email = value.trim();
  if (email.length === 0) return "required";
  if (!strictEmail.isValidSync(email)) return "invalid";
  const lower = email.toLowerCase();
  if (existing.some((channel) => channel.value.toLowerCase() === lower)) return "duplicate";
  return null;
}

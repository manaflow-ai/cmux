import type { CurrentServerUser } from "@stackframe/stack";

export const ALLOWED_TYPEFULLY_DOMAINS = [
  "manaflow.com",
  "manaflow.ai",
  "cmux.com",
] as const;

export type TypefullyUser = {
  readonly id: string;
  readonly email: string;
  readonly displayName: string | null;
};

export type TypefullyAccessDeniedReason =
  | "auth_not_configured"
  | "unauthenticated"
  | "email_missing"
  | "email_unverified"
  | "domain_not_allowed"
  | "google_required";

export type TypefullyAccessResult =
  | { readonly ok: true; readonly user: TypefullyUser }
  | {
      readonly ok: false;
      readonly reason: TypefullyAccessDeniedReason;
      readonly email?: string | null;
    };

type StackUserLike = Pick<
  CurrentServerUser,
  "id" | "displayName" | "primaryEmail" | "primaryEmailVerified" | "oauthProviders"
>;

export function typefullyAccessForUser(user: StackUserLike | null): TypefullyAccessResult {
  if (!user) {
    return { ok: false, reason: "unauthenticated" };
  }

  const email = user.primaryEmail?.trim().toLowerCase() ?? null;
  if (!email) {
    return { ok: false, reason: "email_missing" };
  }
  if (!user.primaryEmailVerified) {
    return { ok: false, reason: "email_unverified", email };
  }
  if (!isAllowedTypefullyEmail(email)) {
    return { ok: false, reason: "domain_not_allowed", email };
  }
  if (!hasGoogleOAuthProvider(user)) {
    return { ok: false, reason: "google_required", email };
  }

  return {
    ok: true,
    user: {
      id: user.id,
      email,
      displayName: user.displayName,
    },
  };
}

export function isAllowedTypefullyEmail(email: string): boolean {
  const domain = email.trim().toLowerCase().split("@").at(-1);
  return ALLOWED_TYPEFULLY_DOMAINS.some((allowed) => domain === allowed);
}

export function hasGoogleOAuthProvider(user: Pick<StackUserLike, "oauthProviders">): boolean {
  return user.oauthProviders.some((provider) => provider.id === "google");
}

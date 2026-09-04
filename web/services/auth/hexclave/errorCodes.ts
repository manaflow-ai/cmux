/**
 * The closed set of auth failures cmux is willing to describe to a visitor.
 *
 * Upstream error text is never rendered: it is written for developers, is not
 * localized, and would leak whether an address has an account. Everything that
 * is not on this list becomes `unexpected`, which reads as an outage.
 */
export type AuthErrorKey =
  | "invalidCredentials"
  | "emailTaken"
  | "weakPassword"
  | "passwordMismatch"
  | "invalidCode"
  | "expiredCode"
  | "usedCode"
  | "tooManyAttempts"
  | "userNotFound"
  | "emailNotVerified"
  | "signUpDisabled"
  | "passwordSignInDisabled"
  | "noPasswordSet"
  | "passkeyFailed"
  | "oauthDenied"
  | "oauthProviderUnavailable"
  | "oauthAccountTaken"
  | "mfaRequired"
  | "invalidEmail"
  | "missingFields"
  | "unexpected";

const KNOWN_ERROR_KEYS: Readonly<Record<string, AuthErrorKey>> = {
  EMAIL_PASSWORD_MISMATCH: "invalidCredentials",
  INVALID_TOTP_CODE: "invalidCode",
  USER_EMAIL_ALREADY_EXISTS: "emailTaken",
  USER_WITH_EMAIL_ALREADY_EXISTS: "emailTaken",
  CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE: "emailTaken",
  PASSWORD_REQUIREMENTS_NOT_MET: "weakPassword",
  PASSWORD_TOO_SHORT: "weakPassword",
  PASSWORD_TOO_LONG: "weakPassword",
  PASSWORD_CONFIRMATION_MISMATCH: "passwordMismatch",
  VERIFICATION_CODE_NOT_FOUND: "invalidCode",
  VERIFICATION_ERROR: "invalidCode",
  VERIFICATION_CODE_EXPIRED: "expiredCode",
  VERIFICATION_CODE_ALREADY_USED: "usedCode",
  VERIFICATION_CODE_MAX_ATTEMPTS_REACHED: "tooManyAttempts",
  USER_NOT_FOUND: "userNotFound",
  EMAIL_NOT_VERIFIED: "emailNotVerified",
  SIGN_UP_NOT_ENABLED: "signUpDisabled",
  SIGN_UP_REJECTED: "signUpDisabled",
  PASSWORD_AUTHENTICATION_NOT_ENABLED: "passwordSignInDisabled",
  USER_DOES_NOT_HAVE_PASSWORD: "noPasswordSet",
  PASSKEY_AUTHENTICATION_FAILED: "passkeyFailed",
  PASSKEY_AUTHENTICATION_NOT_ENABLED: "passkeyFailed",
  PASSKEY_WEBAUTHN_ERROR: "passkeyFailed",
  OAUTH_PROVIDER_ACCESS_DENIED: "oauthDenied",
  OAUTH_PROVIDER_TEMPORARILY_UNAVAILABLE: "oauthProviderUnavailable",
  OAUTH_PROVIDER_NOT_FOUND_OR_NOT_ENABLED: "oauthProviderUnavailable",
  OUTER_OAUTH_TIMEOUT: "oauthProviderUnavailable",
  OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN: "oauthAccountTaken",
  OAUTH_CONNECTION_ALREADY_CONNECTED_TO_ANOTHER_USER: "oauthAccountTaken",
  MULTI_FACTOR_AUTHENTICATION_REQUIRED: "mfaRequired",
};

const AUTH_ERROR_KEYS = new Set<string>(Object.values(KNOWN_ERROR_KEYS));

/**
 * `fallback` is what an unrecognized code means at this call site. On the
 * endpoints that redeem a one-time code, a rejected request is a bad code
 * rather than an outage: the API answers a malformed code with SCHEMA_ERROR,
 * and telling the visitor "something went wrong" would send them to support
 * instead of back to their inbox.
 */
export function authErrorKeyForCode(
  code: string,
  fallback: AuthErrorKey = "unexpected",
): AuthErrorKey {
  return KNOWN_ERROR_KEYS[code] ?? fallback;
}

/**
 * Reads back a key this app put in the query string after a failed POST.
 * Anything else is treated as tampering and shown as the generic failure.
 */
export function parseAuthErrorKey(
  value: string | null | undefined,
): AuthErrorKey | null {
  if (!value) return null;
  if (value === "unexpected" || value === "invalidEmail" ||
    value === "missingFields") {
    return value;
  }
  return AUTH_ERROR_KEYS.has(value) ? (value as AuthErrorKey) : "unexpected";
}

import type { AuthErrorKey } from "../../../services/auth/hexclave/errorCodes";
import type { AuthIntl } from "./auth-intl";

/** Maps a product error key onto its localized sentence. */
export function authErrorMessage(
  intl: AuthIntl,
  key: AuthErrorKey | null,
): string | null {
  if (!key) return null;
  return intl.t(`error${key.charAt(0).toUpperCase()}${key.slice(1)}`);
}

/** Reads the first query value when Next represents a repeated parameter. */
export function firstParam(
  value: string | string[] | undefined,
): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}

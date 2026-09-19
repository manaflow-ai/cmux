export const DISPLAY_NAME_MAX_LENGTH = 64;

/** Validates a requested display name: null clears the label; a non-empty
 * printable string up to 64 chars sets it. Returns undefined on invalid. */
export function normalizedDisplayName(raw: unknown): string | null | undefined {
  if (raw === null) return null;
  if (typeof raw !== "string") return undefined;
  const trimmed = raw.trim();
  if (trimmed.length === 0) return null;
  if (trimmed.length > DISPLAY_NAME_MAX_LENGTH) return undefined;
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(trimmed)) return undefined;
  return trimmed;
}

export const DISPLAY_NAME_VALIDATION_MESSAGE = `displayName must be a printable string of at most ${DISPLAY_NAME_MAX_LENGTH} characters, or null to clear`;

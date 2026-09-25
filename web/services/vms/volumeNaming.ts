import { createHash } from "node:crypto";

/** Stable per-user home volume name. The user id is never embedded in the name. */
export function homeVolumeNameForUser(userId: string): string {
  const digest = createHash("sha256").update(userId).digest("hex").slice(0, 12);
  return `cmux-home-${digest}`;
}

/**
 * Per-machine home volume template. The provider replaces `{machine}` with
 * the final machine name after it resolves a name collision.
 */
export function homeVolumeTemplateForUser(userId: string): string {
  return `${homeVolumeNameForUser(userId)}-{machine}`;
}

/**
 * Names created by `homeVolumeTemplateForUser`.
 *
 * The suffix is deliberately limited to the provider machine-name grammar.
 * The shared per-user volume has no suffix and therefore never matches.
 */
const MACHINE_OWNED_HOME_VOLUME_PATTERN =
  /^cmux-home-[0-9a-f]{12}-[a-z0-9](?:[a-z0-9-]{0,39}[a-z0-9])?$/;

export function isMachineOwnedHomeVolumeName(value: unknown): value is string {
  return typeof value === "string" && MACHINE_OWNED_HOME_VOLUME_PATTERN.test(value.trim());
}


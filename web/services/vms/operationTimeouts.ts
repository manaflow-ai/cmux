/**
 * The provider create/restore calls use this client deadline. Reconciliation
 * waits for two full provider deadlines before declaring a row abandoned so a
 * request that is still inside its own timeout cannot be reclaimed.
 */
export const VM_PROVIDER_CREATE_TIMEOUT_MS = 15 * 60 * 1_000;
export const VM_CREATE_ABANDONED_AFTER_MS = VM_PROVIDER_CREATE_TIMEOUT_MS * 2;

/** Preview tokens are only needed for revocation during their live TTL. */
export const VM_PREVIEW_LEASE_RETENTION_MS = 7 * 24 * 60 * 60 * 1_000;

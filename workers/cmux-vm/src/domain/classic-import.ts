/**
 * Classic -> NEXT migration: a classic VM is copied, never moved. The import route snapshots the classic VM's
 * provider VM and registers that snapshot under the NEXT tenant, labelled with the classic VM id and the migration
 * run that copied it. These labels are the import's identity: the same (tenant, classic VM, migration) answers the
 * same snapshot, and only a snapshot carrying the migration label may be rolled back by the import route.
 */
import type { TenantId } from "../lib/ids.ts";

/**
 * Every label under this prefix is written by the import route only. Caller-writable label inputs (VM create and fork,
 * snapshot create) refuse it with 400, and a service key configured with one is refused by the key parser, so a
 * `classic.*` label on a row is import provenance, not a caller's claim.
 */
export const RESERVED_LABEL_PREFIX = "classic.";
export const hasReservedLabel = (labels: Readonly<Record<string, string>>): boolean =>
  Object.keys(labels).some((key) => key.startsWith(RESERVED_LABEL_PREFIX));

export const CLASSIC_VM_LABEL = "classic.vm_id";
export const CLASSIC_MIGRATION_LABEL = "classic.migration_id";
/** The import marker: the service actor that imported the row (`service:<id>`). List and rollback require it. */
export const CLASSIC_IMPORTER_LABEL = "classic.imported_by";
/** One label per Idempotency-Key bound to an import: this prefix plus a digest of the key, never the key itself. */
export const CLASSIC_IMPORT_KEY_PREFIX = "classic.import_key/";

/** What one import copies: the classic VM, the migration run, and the provider VM behind the classic VM. */
export interface ClassicImportRequest {
  readonly tenantId: TenantId;
  readonly classicVmId: string;
  readonly migrationId: string;
  readonly upstreamVmId: string;
}

export const sha256Hex = async (value: unknown): Promise<string> => {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)));
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
};

/** The import's identity, as a digest: names its provider snapshot and its tenant lock. */
export const classicImportDigest = (request: Pick<ClassicImportRequest, "tenantId" | "classicVmId" | "migrationId">) =>
  sha256Hex(["classic-import:v1", request.tenantId, request.classicVmId, request.migrationId]);

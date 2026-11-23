/**
 * Classic -> NEXT migration: copy a classic VM into a NEXT tenant as a snapshot. Service keys with the
 * service-only `import:classic` scope only (src/domain/scopes.ts). The classic VM is never touched: its provider
 * VM is snapshotted and that snapshot is registered under the tenant, labelled `classic.vm_id` and
 * `classic.migration_id`. Field names are snake_case, as the migration ledger writes them.
 */
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema } from "@effect/platform";
import { Schema } from "effect";
import { BadRequest, Conflict, Forbidden, NotFound, QuotaExceeded } from "../errors.ts";
import { SnapshotId, TenantId, UserId } from "../lib/ids.ts";
import { describe, GroupCreateHeaders, GroupTeamHeaders } from "./common.ts";

/** A classic id or migration run id: a label value (1-63 of letters, digits and . _ : / @ -). */
const ClassicRef = Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9._:/@-]{1,63}$/u));
/** The provider's VM id behind the classic VM (classic cloud_vms.provider_vm_id). */
const UpstreamVmRef = Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9._-]{1,128}$/u));

export class ClassicVmImportRequest extends Schema.Class<ClassicVmImportRequest>("ClassicVmImportRequest")({
  tenant_id: TenantId.annotations({ description: "The NEXT VM API tenant to import into. Must equal X-Cmux-Team-Id." }),
  created_by: UserId.annotations({ description: "The Stack user id that owns the copy; it becomes the snapshot's creator (user:<id>)." }),
  classic_vm_id: ClassicRef.annotations({ description: "The classic VM's id (cloud_vms.id). Stored as label classic.vm_id." }),
  upstream_vm_id: UpstreamVmRef.annotations({ description: "The classic VM's provider VM id (cloud_vms.provider_vm_id)." }),
  migration_id: ClassicRef.annotations({ description: "The migration run. Stored as label classic.migration_id." }),
}) {}

export class ClassicVmImport extends Schema.Class<ClassicVmImport>("ClassicVmImport")({
  id: SnapshotId,
  upstream_snapshot_id: Schema.String.annotations({ description: "The provider snapshot id, for the migration ledger. Returned to the importing service only." }),
  state: Schema.Literal("created", "ready", "deleted").annotations({
    description: "created: this request took and registered the snapshot. ready: an earlier import answered (nothing was snapshotted). deleted: rolled back.",
  }),
  tenant_id: TenantId,
  classic_vm_id: Schema.String,
  migration_id: Schema.String,
  created_by: Schema.String.annotations({ description: "The creator reference, user:<Stack user id>." }),
  created_at: Schema.String,
}, { description: "A classic VM copied into a NEXT tenant as a snapshot." }) {}

export class ClassicVmImportList extends Schema.Class<ClassicVmImportList>("ClassicVmImportList")({
  items: Schema.Array(ClassicVmImport),
}) {}

export const ListClassicVmImportsParams = Schema.Struct({
  tenant_id: TenantId,
  classic_vm_id: Schema.optional(ClassicRef),
  migration_id: Schema.optional(ClassicRef),
  /** Newest first; at most this many (default 100). */
  limit: Schema.optional(Schema.NumberFromString.pipe(Schema.int(), Schema.between(1, 500))),
});

const SnapshotPath = Schema.Struct({ snapshotId: Schema.String });

const NOTE =
  "Service keys with the import:classic scope only (sessions and API keys never hold it); X-Cmux-Team-Id names the tenant, and the key's teams and labels apply.";

/** Endpoints without the Authentication middleware; src/api.ts applies it. */
export class ClassicImportsGroupDefinition extends HttpApiGroup.make("classicImports")
  .add(
    HttpApiEndpoint.post("importClassicVmSnapshot", "/v1/imports/classic-vm-snapshots")
      .setHeaders(GroupCreateHeaders)
      .setPayload(ClassicVmImportRequest)
      .addSuccess(ClassicVmImport)
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Import a classic VM as a snapshot",
          "import:classic",
          `${NOTE} Snapshots the classic VM's provider VM and registers the snapshot under tenant_id, labelled classic.vm_id and classic.migration_id (plus the key's labels). Idempotent: the same (tenant_id, classic_vm_id, migration_id) answers the existing import with state ready and never snapshots twice; an Idempotency-Key reused with a different request is 409. 404 with code import.upstream_vm_not_found: this service's provider account has no such VM (a classic VM in a different provider account shows up this way). The classic VM itself is never changed.`,
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("listClassicVmSnapshotImports", "/v1/imports/classic-vm-snapshots")
      .setHeaders(GroupTeamHeaders)
      .setUrlParams(ListClassicVmImportsParams)
      .addSuccess(ClassicVmImportList)
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(QuotaExceeded)
      .annotateContext(describe("List classic VM imports, newest first, rolled-back ones included", "import:classic", `${NOTE} For dry runs and status. Never contacts the provider.`)),
  )
  .add(
    HttpApiEndpoint.del("rollbackClassicVmSnapshotImport", "/v1/imports/classic-vm-snapshots/:snapshotId")
      .setHeaders(GroupTeamHeaders)
      .setPath(SnapshotPath)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Roll back a classic VM import",
          "import:classic",
          `${NOTE} Deletes the provider snapshot and marks the snapshot deleted, only when it carries classic.migration_id (a snapshot not made by an import is 409 and is never deleted here). Deleting an already rolled-back import succeeds. VMs already created from it keep running.`,
        ),
      ),
  ) {}

/**
 * Trusted module: the only place the classic import proofs are minted (classic -> NEXT migration).
 *
 * ClassicImportAllowed: the caller is a service key holding `import:classic`. Only a service key can hold that
 * scope (src/domain/scopes.ts SERVICE_ONLY_SCOPES), and this proof checks the actor kind as well, so a session or
 * an API key can never snapshot a provider VM by its provider id.
 *
 * ClassicImportedSnapshot: the snapshot the caller owns was made by a classic import (its ownership row carries
 * `classic.migration_id` and the import marker `classic.imported_by`), so the import rollback may delete it. Labels
 * under `classic.` are reserved: no caller-writable label input accepts them (src/domain/classic-import.ts), so only
 * the import route writes them and a user's own snapshot never carries them.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import type { Principal } from "../domain/principal.ts";
import { CLASSIC_IMPORTER_LABEL, CLASSIC_MIGRATION_LABEL } from "../domain/classic-import.ts";
import type { SnapshotId } from "../lib/ids.ts";
import type { KeyHasScope } from "./key-has-scope.ts";
import type { TenantOwnsResource } from "./tenant-owns-resource.ts";

const Allowed = defineProof("ClassicImportAllowed");
const Imported = defineProof("ClassicImportedSnapshot");

/** Caller `C` is a service key that may import classic VMs for its tenant. */
export interface ClassicImportAllowed<C> extends Proof<"ClassicImportAllowed", [C]> {}

/** Snapshot `S`, owned by caller `C`'s tenant, was made by a classic import. */
export interface ClassicImportedSnapshot<C, S> extends Proof<"ClassicImportedSnapshot", [C, S]> {}

export const classicImportAllowed = <C>(caller: Named<C, Principal>, _scope: KeyHasScope<C, "import:classic">): ClassicImportAllowed<C> | null =>
  caller.value.actor.kind === "service" ? Allowed.prove(caller) : null;

export const classicImportedSnapshot = <C, S>(
  caller: Named<C, Principal>,
  snapshot: Named<S, SnapshotId>,
  owns: TenantOwnsResource<C, S>,
  _allowed: ClassicImportAllowed<C>,
): ClassicImportedSnapshot<C, S> | null =>
  isClassicImport(owns.labels) ? Imported.prove(caller, snapshot) : null;

/** A row the import route wrote: the migration label and the import marker, both non-empty. */
export const isClassicImport = (labels: Readonly<Record<string, string>>): boolean =>
  (labels[CLASSIC_MIGRATION_LABEL] ?? "") !== "" && (labels[CLASSIC_IMPORTER_LABEL] ?? "") !== "";

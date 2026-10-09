/**
 * The two migration trees of cmux-next Cloud and where each one lives on
 * PlanetScale (org `cmux`). Release tooling never takes a database, branch or
 * schema from its caller: it takes a tree name and a target, and reads the rest
 * here.
 *
 *   cmux-vm  workers/cmux-vm/migrations   database cmux-prod, schema cmux_vm (the cmux VM API Worker)
 *   backend  backend/db/migrations        database cmux-next, schema public  (the cmux-next API Worker)
 */
import { join } from "node:path"

export type TreeName = "cmux-vm" | "backend"
export type Target = "development" | "staging" | "production"
export const TARGETS: ReadonlyArray<Target> = ["development", "staging", "production"]
export const TREE_NAMES: ReadonlyArray<TreeName> = ["cmux-vm", "backend"]

export interface Tree {
  readonly name: TreeName
  /** Migration directory, relative to the repository root. */
  readonly dir: string
  /** PlanetScale database (org cmux). */
  readonly database: string
  /** PlanetScale branch name of each target. */
  readonly branches: Readonly<Record<Target, string>>
  /** PlanetScale branch ids: a Postgres user name ends in `.<branch id>`, so a URL for another branch is refused. */
  readonly branchIds: Readonly<Record<Target, string>>
  /** Schema of the migrated objects, and of the tracking table. */
  readonly schema: string
  /** Tracking table (`schema.table`), same shape as backend/db/migrate.ts uses: (version, checksum, applied_at). */
  readonly trackingTable: string
  /** Extra tracking columns (cmux-vm only; backend keeps migrate.ts's table unchanged). */
  readonly richTracking: boolean
  /** Advisory lock key; backend shares migrate.ts's key so the two runners exclude each other. */
  readonly lockKey: number
  /** PlanetScale role (name) that owns the objects; rehearsals act as it when they can. */
  readonly ownerRole: string
  /**
   * The Postgres role that owns the objects when it is a SQL role without a PlanetScale record
   * (cmux-vm since 2026-10-09: cmux_vm_migrator, nothing outside cmux_vm). Checked directly.
   */
  readonly ownerPgRole?: string
  /** PlanetScale role (name) the deployed Worker connects as; its privileges are what the Worker gets. */
  readonly workerRole: string
  /** A database row the tree lacks is a warning (expand-first means the database may be ahead of a branch), not a refusal. */
  readonly allowDatabaseAhead: boolean
  /** Name of the Worker per target, for the deploy rails. */
  readonly workers: Readonly<Partial<Record<Target, string>>>
}

export const TREES: Readonly<Record<TreeName, Tree>> = {
  "cmux-vm": {
    name: "cmux-vm",
    dir: "workers/cmux-vm/migrations",
    database: "cmux-prod",
    branches: { development: "development", staging: "staging", production: "main" },
    branchIds: { development: "l87jkp3ubcwt", staging: "qjkoajlaike8", production: "pj68ww4tuq8x" },
    schema: "cmux_vm",
    trackingTable: "cmux_vm.schema_migrations",
    richTracking: true,
    lockKey: 0x636d7576, // "cmuv"
    ownerRole: "cmux-vm-owner",
    ownerPgRole: "cmux_vm_migrator",
    workerRole: "cmux-vm-worker",
    allowDatabaseAhead: true,
    workers: { staging: "cmux-vm-staging" },
  },
  backend: {
    name: "backend",
    dir: "backend/db/migrations",
    database: "cmux-next",
    branches: { development: "development", staging: "staging", production: "main" },
    branchIds: { development: "2o41eh2nrsw8", staging: "qxst3kra77vx", production: "8ih62d5neek9" },
    schema: "public",
    trackingTable: "public.schema_migrations",
    richTracking: false,
    lockKey: 0x636d7578, // backend/db/migrate.ts LOCK_KEY
    ownerRole: "migrator",
    workerRole: "app",
    allowDatabaseAhead: false,
    workers: { development: "cmux-api-development", staging: "cmux-api-staging", production: "cmux-api" },
  },
}

/** The repository root (this file is scripts/cmux-next/release/trees.ts). */
export const REPO_ROOT = join(import.meta.dirname, "..", "..", "..")

export const treeOf = (name: string | undefined): Tree => {
  if (name === "cmux-vm" || name === "backend") return TREES[name]
  throw new Error(`unknown tree ${JSON.stringify(name)}; use cmux-vm or backend`)
}

export const targetOf = (name: string | undefined): Target => {
  if (name === "development" || name === "staging" || name === "production") return name
  throw new Error(`unknown target ${JSON.stringify(name)}; use development, staging or production`)
}

import { readFileSync } from "node:fs";
import { CONTROL_PLANE_RULES } from "../src/rules";
import { HealthSchema, StorageCompatibilitySchema } from "../src/health";
import { STORAGE_SCHEMA_VERSION, STORAGE_WRITE_SCHEMA_VERSION } from "../src/storage/migrations";

type Binding = { name: string; type?: string; class_name?: string; namespace_id?: string; script_name?: string; text?: string };
type Version = { id: string; resources: { bindings: Binding[]; script_runtime?: { migration_tag?: string }; script?: { migration_tag?: string } } };
type Migration = { tag: string; new_sqlite_classes?: string[]; [key: string]: unknown };
type Config = { migrations: Migration[]; env: Record<string, { name: string; vars: Record<string, string>; durable_objects: { bindings: Binding[] } }> };
type StoragePolicy = { maxSchemaVersion: number; writeSchemaVersion: number };

const targets = { production: "cmux-v2", staging: "cmux-v2-staging" } as const;
type Environment = keyof typeof targets;
export const candidateStorage: StoragePolicy = { maxSchemaVersion: STORAGE_SCHEMA_VERSION, writeSchemaVersion: STORAGE_WRITE_SCHEMA_VERSION };

// These immutable versions were inspected read-only before the rollout: their
// migration readers support schema 6 and their health route is absent. Unknown
// pre-health versions must be audited, never inferred compatible from a 404.
const legacyVersions = {
  production: "bd1538b8-b29f-430f-a33f-119bd41e4118",
  staging: "e0f72d8d-7db8-423e-a207-f03882523887",
} as const;

function environment(value: string): Environment {
  if (value !== "production" && value !== "staging") throw new Error("Unsupported rollout environment");
  return value;
}

// Team and usage storage predate every guarded rollout. Account storage is
// additive (its own migration tag and class): a version deployed before it
// existed has no ACCOUNT_CONTROL binding, and once present it must persist.
const durableObjects = { TEAM_CONTROL: "TeamControl", USER_USAGE: "UserUsage", ACCOUNT_CONTROL: "AccountControl" } as const;
const additiveDurableObjects: ReadonlySet<string> = new Set(["ACCOUNT_CONTROL"]);

function migrationTag(version: Version): string | undefined {
  return version.resources.script_runtime?.migration_tag ?? version.resources.script?.migration_tag;
}

/**
 * The guarded path for a Durable Object migration. Every pending migration is
 * refused unless the operator names it exactly (IROH_V2_APPLY_MIGRATION), it
 * is the only pending one, and it only adds a new SQLite class this policy
 * already treats as additive. Existing classes are never renamed, deleted or
 * transferred by this path. Returns "apply" when such a migration will run.
 */
export function migrationPlan(config: Config, previous: Version, allow: string | undefined): "none" | "apply" {
  const latest = config.migrations.at(-1);
  const current = migrationTag(previous);
  if (!latest || current === latest.tag) return "none";
  if (allow !== latest.tag) throw new Error("Pending Durable Object migration; set IROH_V2_APPLY_MIGRATION to its exact tag for the dedicated migration rollout");
  if (current !== config.migrations.at(-2)?.tag) throw new Error("Pending Durable Object migration: the migration rollout applies exactly one pending migration");
  const additiveClasses = new Set([...additiveDurableObjects].map(name => durableObjects[name as keyof typeof durableObjects]));
  if (Object.keys(latest).some(key => key !== "tag" && key !== "new_sqlite_classes") || !latest.new_sqlite_classes?.length
    || !latest.new_sqlite_classes.every(name => additiveClasses.has(name as never))) {
    throw new Error("Pending Durable Object migration is not an additive SQLite class; it needs its own reviewed rollout");
  }
  return "apply";
}

/** Production applies a migration only after staging already runs it. */
export function assertMigrated(config: Config, version: Version): void {
  if (migrationTag(version) !== config.migrations.at(-1)?.tag) throw new Error("Staging has not applied the pending Durable Object migration; deploy staging first");
}

export function assertTarget(config: Config, lane: Environment): void {
  const target = config.env[lane];
  if (!target || target.name !== targets[lane] || target.vars.ENVIRONMENT !== lane) throw new Error("Refusing noncanonical Worker target");
  const bindings = target.durable_objects.bindings;
  const expected = Object.entries(durableObjects);
  if (bindings.length !== expected.length || !expected.every(([name, className]) => bindings.some(binding =>
    binding.name === name && binding.class_name === className && Object.keys(binding).every(key => ["name", "class_name"].includes(key))))) {
    throw new Error("Refusing changed Durable Object configuration");
  }
}

function storageBindings(version: Version): Record<string, string> {
  const bindings = version.resources.bindings;
  const result: Record<string, string> = {};
  if (bindings.some(binding => binding.type === "service")) throw new Error("Refusing a forwarding alias");
  for (const [name, className] of Object.entries(durableObjects)) {
    const found = bindings.filter(binding => binding.name === name);
    if (found.length === 0 && additiveDurableObjects.has(name)) continue;
    const binding = found[0];
    if (found.length !== 1 || !binding || binding.type !== "durable_object_namespace" || binding.class_name !== className
      || typeof binding.namespace_id !== "string" || !binding.namespace_id || binding.script_name) throw new Error("Cannot verify existing Durable Object namespaces");
    result[name] = binding.namespace_id;
  }
  if (bindings.filter(binding => binding.type === "durable_object_namespace").length !== Object.keys(result).length) throw new Error("Unexpected Durable Object binding");
  return result;
}

function verifiedHealth(version: Version, health: unknown, lane: Environment) {
  const value = HealthSchema.parse(health);
  const revision = version.resources.bindings.find(binding => binding.name === "CMUX_SOURCE_REVISION" && binding.type === "plain_text")?.text;
  if (value.environment !== lane || !revision || !/^[0-9a-f]{40}$/.test(revision) || value.sourceRevision !== revision) {
    throw new Error("Health does not match the captured deployment revision and environment");
  }
  return value;
}

export function assertRollout(config: Config, previous: Version, health: unknown, status: number, lane: Environment, candidate = candidateStorage, allowMigration?: string): void {
  assertTarget(config, lane);
  storageBindings(previous);
  StorageCompatibilitySchema.parse(candidate);
  migrationPlan(config, previous, allowMigration);
  let prior: StoragePolicy;
  if (status === 404 && previous.id === legacyVersions[lane]) {
    prior = { maxSchemaVersion: 6, writeSchemaVersion: 6 };
  } else if (status === 200) {
    prior = StorageCompatibilitySchema.parse(verifiedHealth(previous, health, lane).storage);
  } else {
    throw new Error("No verified SQLite rollback compatibility for the active version");
  }
  if (candidate.writeSchemaVersion > prior.maxSchemaVersion || candidate.maxSchemaVersion < prior.maxSchemaVersion) {
    throw new Error("SQLite upgrade has no compatible rollback reader; deploy a reader-first version before raising the write version");
  }
}

export function assertPublished(previous: Version, current: Version, health: unknown, status: number, lane: Environment, sourceRevision: string): void {
  const before = storageBindings(previous), after = storageBindings(current);
  if (Object.keys(before).some(key => before[key] !== after[key])) throw new Error("Durable Object namespace changed");
  if (Object.keys(durableObjects).some(key => !after[key])) throw new Error("Published Worker is missing a Durable Object namespace");
  if (status !== 200) throw new Error("Published Worker health is unavailable");
  const value = verifiedHealth(current, health, lane);
  if (value.sourceRevision !== sourceRevision || CONTROL_PLANE_RULES.some(rule => !value.rules.includes(rule))) {
    throw new Error("Published Worker source or Mac admission rule differs from the candidate");
  }
  const storage = StorageCompatibilitySchema.parse(value.storage);
  if (storage.maxSchemaVersion !== candidateStorage.maxSchemaVersion || storage.writeSchemaVersion !== candidateStorage.writeSchemaVersion) {
    throw new Error("Published SQLite compatibility differs from the candidate");
  }
}

if (import.meta.main) {
  try {
    const [operation, laneValue = "production", versionPath, healthPath, statusValue, currentPath, revision] = process.argv.slice(2);
    const lane = environment(laneValue);
    const read = (path: string | undefined) => JSON.parse(readFileSync(path!, "utf8"));
    const config = read(new URL("../wrangler.jsonc", import.meta.url).pathname) as Config;
    if (operation === "target") assertTarget(config, lane);
    else if (operation === "pre") assertRollout(config, read(versionPath), read(healthPath), Number(statusValue), lane, candidateStorage, process.env.IROH_V2_APPLY_MIGRATION);
    else if (operation === "migration") {
      // Exit 10 tells the deploy script a migration will be applied (and rollback must be disabled).
      if (migrationPlan(config, read(versionPath), process.env.IROH_V2_APPLY_MIGRATION) === "apply") {
        console.log("Applying the additive Durable Object migration " + config.migrations.at(-1)!.tag);
        process.exit(10);
      }
    }
    else if (operation === "migrated") assertMigrated(config, read(versionPath));
    else if (operation === "post") assertPublished(read(versionPath), read(currentPath), read(healthPath), Number(statusValue), lane, revision!);
    else throw new Error("Unsupported rollout policy operation");
    console.log("Worker target, storage and rollback policy verified");
  } catch (error) {
    // Do not echo remote metadata, which may include private plain-text vars.
    console.error(`Rollout refused: ${error instanceof Error && !(error instanceof SyntaxError) ? error.message : "invalid deployment metadata"}`);
    process.exitCode = 1;
  }
}

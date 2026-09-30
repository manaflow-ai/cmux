import { readFileSync } from "node:fs";
import { CONTROL_PLANE_RULES } from "../src/rules";
import { HealthSchema, StorageCompatibilitySchema } from "../src/health";
import { STORAGE_SCHEMA_VERSION, STORAGE_WRITE_SCHEMA_VERSION } from "../src/storage/migrations";

type Binding = { name: string; type?: string; class_name?: string; namespace_id?: string; script_name?: string; text?: string };
type Version = { id: string; resources: { bindings: Binding[]; script_runtime?: { migration_tag?: string }; script?: { migration_tag?: string } } };
type Config = { migrations: { tag: string }[]; env: Record<string, { name: string; vars: Record<string, string>; durable_objects: { bindings: Binding[] } }> };
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

export function assertTarget(config: Config, lane: Environment): void {
  const target = config.env[lane];
  if (!target || target.name !== targets[lane] || target.vars.ENVIRONMENT !== lane) throw new Error("Refusing noncanonical Worker target");
  const bindings = target.durable_objects.bindings;
  if (bindings.length !== 2 || !["TeamControl", "UserUsage"].every((name, i) => bindings.some(binding =>
    binding.name === ["TEAM_CONTROL", "USER_USAGE"][i] && binding.class_name === name && Object.keys(binding).every(key => ["name", "class_name"].includes(key))))) {
    throw new Error("Refusing changed Durable Object configuration");
  }
}

function storageBindings(version: Version): Record<string, string> {
  const bindings = version.resources.bindings;
  const expected = { TEAM_CONTROL: "TeamControl", USER_USAGE: "UserUsage" };
  const result: Record<string, string> = {};
  if (bindings.some(binding => binding.type === "service")) throw new Error("Refusing a forwarding alias");
  for (const [name, className] of Object.entries(expected)) {
    const found = bindings.filter(binding => binding.name === name);
    const binding = found[0];
    if (found.length !== 1 || !binding || binding.type !== "durable_object_namespace" || binding.class_name !== className
      || typeof binding.namespace_id !== "string" || !binding.namespace_id || binding.script_name) throw new Error("Cannot verify existing Durable Object namespaces");
    result[name] = binding.namespace_id;
  }
  if (bindings.filter(binding => binding.type === "durable_object_namespace").length !== 2) throw new Error("Unexpected Durable Object binding");
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

export function assertRollout(config: Config, previous: Version, health: unknown, status: number, lane: Environment, candidate = candidateStorage): void {
  assertTarget(config, lane);
  storageBindings(previous);
  StorageCompatibilitySchema.parse(candidate);
  const migration = previous.resources.script_runtime?.migration_tag ?? previous.resources.script?.migration_tag;
  if (migration !== config.migrations.at(-1)?.tag) throw new Error("Pending Durable Object migration");
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
    else if (operation === "pre") assertRollout(config, read(versionPath), read(healthPath), Number(statusValue), lane);
    else if (operation === "post") assertPublished(read(versionPath), read(currentPath), read(healthPath), Number(statusValue), lane, revision!);
    else throw new Error("Unsupported rollout policy operation");
    console.log("Worker target, storage and rollback policy verified");
  } catch (error) {
    // Do not echo remote metadata, which may include private plain-text vars.
    console.error(`Rollout refused: ${error instanceof Error && !(error instanceof SyntaxError) ? error.message : "invalid deployment metadata"}`);
    process.exitCode = 1;
  }
}

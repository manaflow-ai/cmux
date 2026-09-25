import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { assertPublished, assertRollout, assertTarget, candidateStorage } from "../scripts/rollout-policy";

const config = JSON.parse(readFileSync(new URL("../wrangler.jsonc", import.meta.url).pathname, "utf8"));
const revision = "a".repeat(40);
const bindings = [
  {name: "TEAM_CONTROL", type: "durable_object_namespace", class_name: "TeamControl", namespace_id: "existing-team"},
  {name: "USER_USAGE", type: "durable_object_namespace", class_name: "UserUsage", namespace_id: "existing-user"},
  {name: "CMUX_SOURCE_REVISION", type: "plain_text", text: revision},
];
const version = (id = "current"): Parameters<typeof assertPublished>[0] => ({id, resources: {bindings: structuredClone(bindings), script_runtime: {migration_tag: "iroh-v2-fresh-storage-1"}}});
const health = () => ({schemaId: "health.v1", environment: "production", sourceRevision: revision,
  rules: ["cmux.mac-peer-inbound.v1"], storage: {...candidateStorage}});

test("only canonical production and staging targets are deployable", () => {
  assertTarget(config, "production");
  assertTarget(config, "staging");
  const alias = structuredClone(config);
  alias.env.production.name = "cmux-iroh-v2";
  expect(() => assertTarget(alias, "production")).toThrow("noncanonical");
  alias.env.production = {...config.env.production, durable_objects: {bindings: []}};
  expect(() => assertTarget(alias, "production")).toThrow("Durable Object");
  const foreignEnvironment = structuredClone(config);
  foreignEnvironment.env.production.durable_objects.bindings[0].environment = "staging";
  expect(() => assertTarget(foreignEnvironment, "production")).toThrow("Durable Object");
});

test("audited legacy v6 can receive the reader-first rollout but cannot receive a v7 writer", () => {
  const legacy = version("bd1538b8-b29f-430f-a33f-119bd41e4118");
  assertRollout(config, legacy, {}, 404, "production");
  expect(() => assertRollout(config, legacy, {}, 404, "production", {maxSchemaVersion: 7, writeSchemaVersion: 7})).toThrow("rollback reader");
  expect(() => assertRollout(config, version("unknown"), {}, 404, "production")).toThrow("No verified");
  expect(() => assertRollout(config, legacy, {}, 503, "production")).toThrow("No verified");
});

test("a verified v7 reader permits a later writer without allowing reader downgrades", () => {
  assertRollout(config, version(), health(), 200, "production", {maxSchemaVersion: 7, writeSchemaVersion: 7});
  expect(() => assertRollout(config, version(), health(), 200, "production", {maxSchemaVersion: 6, writeSchemaVersion: 6})).toThrow("rollback reader");
});

test("health from another version or environment cannot authorize a migration", () => {
  for (const h of [ {...health(), sourceRevision: "b".repeat(40)}, {...health(), environment: "staging"}, {...health(), storage: undefined} ]) {
    expect(() => assertRollout(config, version(), h, 200, "production")).toThrow();
  }
});

test("aliases and missing or redirected storage bindings are refused", () => {
  for (const changed of [ [], [{name: "CANONICAL", type: "service"}],
    bindings.map(binding => binding.name === "TEAM_CONTROL" ? {...binding, script_name: "another-worker"} : binding),
    bindings.map(binding => binding.name === "USER_USAGE" ? {...binding, namespace_id: ""} : binding),
  ]) {
    const v = version();
    v.resources.bindings = changed;
    expect(() => assertRollout(config, v, health(), 200, "production")).toThrow();
  }
});

test("post-deploy verification requires the same namespaces, candidate revision, rules and schema policy", () => {
  assertPublished(version(), version("new"), health(), 200, "production", revision);
  const changed = version("new");
  changed.resources.bindings[0]!.namespace_id = "replacement-storage";
  expect(() => assertPublished(version(), changed, health(), 200, "production", revision)).toThrow("namespace changed");
  for (const h of [ {...health(), rules: []}, {...health(), sourceRevision: "b".repeat(40)},
    {...health(), storage: {maxSchemaVersion: 7, writeSchemaVersion: 7}} ]) {
    expect(() => assertPublished(version(), version("new"), h, 200, "production", revision)).toThrow();
  }
  expect(() => assertPublished(version(), version("new"), health(), 404, "production", revision)).toThrow();
});

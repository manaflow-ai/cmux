#!/usr/bin/env bun
const [resourcePath, cloudPath, relayPath] = Bun.argv.slice(2);
if (!resourcePath || !cloudPath || !relayPath) throw new Error("usage: code-mode-catalog-bench.mjs RESOURCE CLOUD RELAY");
const started = performance.now();
const [resource, cloud, relay] = await Promise.all([
  Bun.file(resourcePath).json(),
  Bun.file(cloudPath).json(),
  Bun.file(relayPath).json(),
]);
const loaded = performance.now();
const operations = { ...relay.operations, ...resource.operations, ...cloud.operations };
let found = 0;
for (const name of ["workspace.list", "session.list", "cloud.machine.list", "does.not.exist"]) {
  if (Object.hasOwn(operations, name)) found += 1;
}
const finished = performance.now();
console.log(JSON.stringify({ loaded_ms: loaded - started, lookup_ms: finished - loaded, total_ms: finished - started, operation_count: Object.keys(operations).length, found }));

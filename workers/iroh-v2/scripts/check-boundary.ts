import { dirname, relative, resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const sourceRoot = resolve(root, "src");
const generatedWire = resolve(root, "generated/wire");
const errors: string[] = [];
const allowed = new Set(["zod", "drizzle-orm", "cloudflare:workers"]);
const scanner = new Bun.Transpiler({ loader: "ts" });
let files = 0;
for await (const path of new Bun.Glob("**/*.ts").scan({ cwd: sourceRoot, absolute: true })) {
  files++;
  const source = await Bun.file(path).text();
  function checkImport(value: string) {
    const label = relative(root, path);
    if (value.startsWith(".")) {
      const target = resolve(dirname(path), value);
      if (!target.startsWith(sourceRoot + "/") && target !== generatedWire) errors.push(label + " imports outside the v2 backend: " + value);
    } else if (value === "postgres") {
      if (relative(sourceRoot, path) !== "ownership/planetscale.ts") errors.push(label + " uses PlanetScale outside the ownership adapter");
    } else if (!allowed.has(value) && !value.startsWith("drizzle-orm/")) {
      errors.push(label + " imports an unapproved backend dependency: " + value);
    }
  }
  for (const dependency of scanner.scanImports(source)) checkImport(dependency.path);
  // Type-only imports are erased by the runtime scanner but still belong to
  // the architectural boundary. Their module specifiers must be literals.
  for (const match of source.matchAll(/(?:import|export)\s+type\s+[\s\S]*?\bfrom\s+["']([^"']+)["']/g)) checkImport(match[1]!);
}
const config = JSON.parse(await Bun.file(resolve(root, "wrangler.jsonc")).text());
for (const environment of [config, ...Object.values(config.env ?? {})] as Record<string, unknown>[]) {
  if (environment.hyperdrive) errors.push("v2 configuration declares Hyperdrive");
  if (environment.services) errors.push("v2 configuration declares an unreviewed external service binding");
}
if (errors.length) throw new Error(errors.join("\n"));
console.log(`Verified ${files} v2 source files: Cloudflare boundary and isolated PlanetScale ownership adapter`);

import { expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// Run with the isolated test runner and no module mocks. Discover new files
// automatically so incomplete mocks cannot conceal broken real imports.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const paths = [
  ...readdirSync(resolve(root, "app/api/coderouter"), { recursive: true, encoding: "utf8" })
    .filter((path) => path.endsWith("/route.ts") || path === "route.ts")
    .map((path) => `app/api/coderouter/${path}`),
  ...readdirSync(resolve(root, "services/coderouter"), { recursive: true, encoding: "utf8" })
    .filter((path) => path.endsWith(".ts"))
    .map((path) => `services/coderouter/${path}`),
].sort();

test("discovers CodeRouter routes and services", () => {
  expect(paths.some((path) => path.startsWith("app/api/coderouter/"))).toBe(true);
  expect(paths.some((path) => path.startsWith("services/coderouter/"))).toBe(true);
});

for (const path of paths) {
  test(`loads ${path} without mocks`, async () => {
    const loaded = await import(pathToFileURL(resolve(root, path)).href);
    expect(loaded).toBeDefined();
    if (path.endsWith("/route.ts")) {
      expect(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
        .some((method) => typeof loaded[method] === "function")).toBe(true);
    }
  });
}

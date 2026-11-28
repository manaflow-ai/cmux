import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import * as core from "../src/index.ts"

describe("package surface", () => {
  test("the root export carries the importer, the policy and every format namespace", () => {
    expect(typeof core.importDocument).toBe("function")
    expect(typeof core.importText).toBe("function")
    expect(typeof core.resolveEffectivePolicy).toBe("function")
    expect(typeof core.defaultActionFor).toBe("function")
    expect(typeof core.openapi.extract).toBe("function")
    expect(typeof core.openapiPaths.planToolPaths).toBe("function")
    expect(typeof core.openapiAuth.authMethodsFromOpenApi).toBe("function")
    expect(typeof core.graphql.extract).toBe("function")
    expect(typeof core.mcp.extractManifestFromListToolsResult).toBe("function")
  })

  test("every subpath export loads as a module", async () => {
    const pkg = JSON.parse(readFileSync(join(import.meta.dir, "../package.json"), "utf8")) as { exports: Record<string, string> }
    for (const target of Object.values(pkg.exports)) {
      const mod = (await import(join(import.meta.dir, "..", target))) as Record<string, unknown>
      expect(Object.keys(mod).length).toBeGreaterThan(0)
    }
  })
})

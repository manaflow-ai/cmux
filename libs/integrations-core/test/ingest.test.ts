import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { authChoices, credentialKindOf } from "../src/auth.ts"
import { catalogBlobBytes, catalogDigest, defaultCounts, detectKind, ImportError, importDocument, importText, isCommandLine } from "../src/catalog.ts"
import { CATALOG_BLOB_MAX_BYTES } from "../src/egress.ts"
import { extract as extractGraphql, toolsFromGraphql } from "../src/graphql.ts"
import { deriveMcpNamespace, extractManifestFromListToolsResult, hostnameOf } from "../src/mcp.ts"
import { extract as extractOpenApi } from "../src/openapi.ts"
import { planToolPaths } from "../src/openapi-paths.ts"

const fixture = (name: string) => JSON.parse(readFileSync(join(import.meta.dir, "fixtures", name), "utf8"))
const byPath = <T extends { path: string }>(tools: readonly T[]) => Object.fromEntries(tools.map((t) => [t.path, t]))

describe("OpenAPI ingestion", () => {
  const doc = fixture("openapi-taskboard.json")

  test("extracts every operation with merged path parameters and resolved refs", () => {
    const result = extractOpenApi(doc)
    expect(result.title).toBe("Taskboard API")
    expect(result.servers).toEqual(["https://eu.taskboard.example.com/api"])
    expect(result.operations.map((o) => `${o.method} ${o.pathTemplate}`)).toEqual([
      "get /health",
      "get /v1/projects",
      "post /v1/projects",
      "get /v1/projects/{projectId}",
      "delete /v1/projects/{projectId}",
      "patch /v1/projects/{projectId}",
      "get /v1/projects/{projectId}/tasks",
      "post /v1/projects/{projectId}/tasks"
    ])
    const get = result.operations.find((o) => o.operationId === "getProject")!
    expect(get.parameters).toEqual([{ name: "projectId", location: "path", required: true, schema: { type: "string" } }])
    expect(get.inputSchema).toMatchObject({ required: ["projectId"], additionalProperties: false })
  })

  test("derives an operation id when the spec has none", () => {
    const health = extractOpenApi(doc).operations.find((o) => o.pathTemplate === "/health")!
    expect(health.operationId).toBe("get__health")
  })

  test("request bodies: required body, refs kept, several media types offer contentType", () => {
    const ops = extractOpenApi(doc).operations
    const create = ops.find((o) => o.operationId === "createProject")!
    expect(create.inputSchema).toMatchObject({ properties: { body: { $ref: "#/components/schemas/ProjectInput" } }, required: ["body"] })
    const patch = ops.find((o) => o.operationId === "updateProject")!
    expect((patch.inputSchema as { properties: Record<string, unknown> }).properties.contentType).toEqual({
      type: "string",
      enum: ["application/json", "application/merge-patch+json"],
      default: "application/json"
    })
  })

  test("security: operation scopes override the document; security: [] disables it", () => {
    const ops = extractOpenApi(doc).operations
    expect(ops.find((o) => o.operationId === "createProject")!.requiredScopeAlternatives).toEqual([["projects:write"]])
    expect(ops.find((o) => o.pathTemplate === "/health")!.requiredScopeAlternatives).toBeUndefined()
  })

  test("tool paths group by tag and keep camel-case leaves", () => {
    const catalog = importDocument(doc)
    expect(catalog.tools.map((t) => t.path)).toEqual([
      "health.getHealth",
      "projects.createProject",
      "projects.deleteProject",
      "projects.getProject",
      "projects.listProjects",
      "projects.updateProject",
      "tasks.createTask",
      "tasks.listTasks"
    ])
  })

  test("policy defaults: GET allows, POST and PATCH ask, DELETE blocks", () => {
    const tools = byPath(importDocument(doc).tools)
    expect(tools["projects.listProjects"]).toMatchObject({ method: "GET", op_class: "read", default_action: "allow" })
    expect(tools["projects.createProject"]).toMatchObject({ method: "POST", op_class: "mutate-shared", default_action: "ask" })
    expect(tools["projects.updateProject"]).toMatchObject({ op_class: "mutate-shared", default_action: "ask" })
    expect(tools["projects.deleteProject"]).toMatchObject({ method: "DELETE", op_class: "destructive", default_action: "block" })
    expect(tools["tasks.createTask"]!.deprecated).toBe(true)
    expect(defaultCounts(importDocument(doc).tools)).toEqual({ allow: 4, ask: 3, block: 1 })
  })

  test("auth methods name where the secret goes and never hold one", () => {
    const { auth } = importDocument(doc)
    expect(auth).toEqual([
      { kind: "bearer", label: "Bearer token", headers: ["Authorization"] },
      { kind: "api_key", label: "apiKey", headers: ["X-Api-Key"] },
      {
        kind: "oauth2",
        flow: "authorization_code",
        label: "OAuth2 · oauth",
        authorization_url: "https://taskboard.example.com/oauth/authorize",
        token_url: "https://taskboard.example.com/oauth/token",
        scopes: ["projects:read", "projects:write"]
      }
    ])
  })

  test("colliding tool paths get a version segment, then a method suffix", () => {
    const op = (operationId: string, method: string, pathTemplate: string) => ({ operationId, explicitToolPath: undefined, method, pathTemplate, tag0: undefined })
    expect(planToolPaths([op("listItems", "get", "/v1/items"), op("listItems", "get", "/v2/items")]).map((p) => p.toolPath)).toEqual(["items.v1.listItems", "items.v2.listItems"])
    expect(planToolPaths([op("list", "get", "/items"), op("list", "post", "/items")]).map((p) => p.toolPath)).toEqual(["items.listGet", "items.listPost"])
  })
})

describe("GraphQL ingestion", () => {
  const doc = fixture("graphql-introspection.json")

  test("queries and mutations become tools; internal fields are skipped", () => {
    const { fields, definitions } = extractGraphql(doc)
    expect(fields.map((f) => `${f.kind}.${f.fieldName}`)).toEqual(["query.project", "query.projects", "mutation.createProject", "mutation.deleteProject", "mutation.deleted"])
    expect(fields[0]!.arguments).toEqual([{ name: "id", typeName: "ID!", required: true }])
    expect(definitions.Status).toEqual({ type: "string", enum: ["OPEN", "DONE"] })
    expect(definitions.ProjectInput).toMatchObject({ required: ["name"], properties: { tags: { type: "array", items: { type: "string" } } } })
  })

  test("defaults: queries allow, mutations ask, destructive-verb mutations block", () => {
    const tools = byPath(toolsFromGraphql(extractGraphql(doc).fields))
    expect(tools["query.projects"]).toMatchObject({ default_action: "allow", input_schema: { properties: { status: { $ref: "#/$defs/Status" } } } })
    expect(tools["mutation.createProject"]!.default_action).toBe("ask")
    expect(tools["mutation.deleteProject"]).toMatchObject({ op_class: "destructive", default_action: "block" })
    expect(tools["mutation.deleted"]!.default_action).toBe("ask")
  })

  test("accepts the bare __schema and names the namespace after the endpoint host", () => {
    const catalog = importDocument(doc.data, { sourceUrl: "https://api.taskboard.example.com/graphql" })
    expect(catalog).toMatchObject({ kind: "graphql", namespace: "api_taskboard_example_com", title: "api.taskboard.example.com" })
  })
})

describe("MCP ingestion", () => {
  const doc = fixture("mcp-tools.json")

  test("sanitizes and de-duplicates tool ids and skips nameless tools", () => {
    const manifest = extractManifestFromListToolsResult(doc, { serverInfo: { name: "Docs Server", version: "1.2.0" } })
    expect(manifest.server).toEqual({ name: "Docs Server", version: "1.2.0" })
    expect(manifest.tools.map((t) => [t.toolId, t.toolName])).toEqual([
      ["search_docs", "search_docs"],
      ["create_page", "create-page"],
      ["create_page_2", "create page"],
      ["delete_page", "Delete Page"]
    ])
  })

  test("defaults: read-only allows, destructive blocks, un-annotated asks", () => {
    const catalog = importDocument({ jsonrpc: "2.0", id: 1, result: doc }, { serverInfo: { name: "Docs Server" } })
    expect(catalog.namespace).toBe("docs_server")
    const tools = byPath(catalog.tools)
    expect(tools.search_docs!.default_action).toBe("allow")
    expect(tools.create_page!.default_action).toBe("ask")
    expect(tools.delete_page).toMatchObject({ title: "Delete a page", default_action: "block" })
  })

  test("namespace falls back to the endpoint host without the URL global", () => {
    expect(hostnameOf("https://user@mcp.docs.example.com:8443/mcp?x=1")).toBe("mcp.docs.example.com")
    expect(deriveMcpNamespace({ endpoint: "https://mcp.docs.example.com/mcp" })).toBe("mcp_docs_example_com")
    expect(deriveMcpNamespace({})).toBe("mcp")
  })
})

describe("one importer", () => {
  test("detects the format of each document", () => {
    expect(detectKind(fixture("openapi-taskboard.json"))).toBe("openapi")
    expect(detectKind(fixture("graphql-introspection.json"))).toBe("graphql")
    expect(detectKind(fixture("mcp-tools.json"))).toBe("mcp")
    expect(detectKind({ swagger: "2.0" })).toBe("swagger2")
    expect(detectKind([1, 2])).toBeNull()
  })

  test("rejects what it cannot ingest with a code", () => {
    const code = (fn: () => unknown) => {
      try {
        fn()
      } catch (e) {
        return e instanceof ImportError ? e.code : "other"
      }
      return "none"
    }
    expect(code(() => importText("openapi: 3.0.0"))).toBe("import.invalid_json")
    expect(code(() => importText('{"swagger":"2.0"}'))).toBe("import.swagger2")
    expect(code(() => importText('{"hello":1}'))).toBe("import.unknown_format")
    expect(code(() => importText('{"tools":[]}'))).toBe("import.no_tools")
  })

  test("the digest changes when the tool list changes and not when descriptions do", () => {
    const a = importDocument(fixture("mcp-tools.json"))
    const reworded = fixture("mcp-tools.json")
    reworded.tools[0].description = "Search everything."
    expect(importDocument(reworded).digest).toBe(a.digest)
    const removed = fixture("mcp-tools.json")
    removed.tools.splice(1, 1)
    expect(importDocument(removed).digest).not.toBe(a.digest)
    expect(a.digest).toBe(catalogDigest("mcp", a.tools))
  })
})

describe("MCP transport: Streamable HTTP only", () => {
  test("stdio launch configs are refused, not ingested", () => {
    for (const doc of [{ command: "npx", args: ["-y", "some-server"] }, { type: "stdio", command: "server" }, { mcpServers: { docs: { command: "uvx", args: ["docs-server"] } } }]) {
      expect(detectKind(doc)).toBe("mcp_stdio")
      expect(() => importDocument(doc)).toThrow(expect.objectContaining({ code: "import.mcp_stdio" }))
    }
    expect(detectKind({ mcpServers: { docs: { url: "https://mcp.docs.example.com/mcp" } } })).toBeNull()
  })

  test("command lines are recognized so a client can say why", () => {
    for (const text of ["npx -y docs-server", "uvx docs-server", "docker run -i docs", "./bin/server --stdio", "python3 server.py"]) expect(`${text}:${isCommandLine(text)}`).toBe(`${text}:true`)
    for (const text of ["https://mcp.docs.example.com/mcp", "{\"tools\":[]}", "taskboard"]) expect(`${text}:${isCommandLine(text)}`).toBe(`${text}:false`)
  })

  test("an MCP tool list declares no auth; the add flow offers OAuth with dynamic registration first", () => {
    const catalog = importDocument(fixture("mcp-tools.json"), { sourceUrl: "https://mcp.docs.example.com/mcp" })
    expect(catalog.auth).toEqual([])
    expect(authChoices("mcp", catalog.auth)).toEqual([{ kind: "oauth2_code", dynamic_registration: true }, { kind: "bearer" }, { kind: "headers" }, { kind: "none" }])
  })
})

describe("catalog blob cap", () => {
  test("a catalog larger than 2 MB is refused with catalog.too_large", () => {
    const tools = Array.from({ length: 4000 }, (_, i) => ({ name: `tool_${i}`, description: "d".repeat(600), annotations: { readOnlyHint: true } }))
    expect(() => importDocument({ tools })).toThrow(expect.objectContaining({ code: "catalog.too_large" }))
    const small = importDocument({ tools: tools.slice(0, 10) })
    expect(catalogBlobBytes(small)).toBeLessThan(CATALOG_BLOB_MAX_BYTES)
  })
})

describe("auth choices", () => {
  test("declared methods first, then every other kind; credential kinds name the OAuth flow", () => {
    const doc = fixture("openapi-taskboard.json")
    const choices = authChoices("openapi", importDocument(doc).auth)
    expect(choices.map((c) => c.kind)).toEqual(["bearer", "api_key", "oauth2_code", "basic", "headers", "oauth2_client_credentials", "none"])
    expect(choices[1]!.method?.headers).toEqual(["X-Api-Key"])
    expect(choices[3]!.method).toBeUndefined()
    expect(credentialKindOf({ kind: "oauth2", flow: "client_credentials", label: "x" })).toBe("oauth2_client_credentials")
  })
})

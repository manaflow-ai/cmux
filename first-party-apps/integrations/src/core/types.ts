// Shared types of the integration catalog core (src/core). The core is pure
// TypeScript with no cmux globals so it can move unchanged into a backend
// package (README, "Code placement"). Files marked "Adapted from executor"
// carry upstream code under the MIT License (see LICENSE-executor).

/** Per-tool policy: run without asking, ask the user each call, or never run. */
export type ToolAction = "allow" | "ask" | "block"

/** cmux op classes (protocol `OpClass`). Defaults derive from these. */
export type OpClass = "read" | "mutate-own" | "mutate-shared" | "execute" | "send-external" | "money" | "destructive"

/** Generic integration kinds. First-class providers (GitHub, Linear, ...) are not catalog kinds. */
export type CatalogKind = "openapi" | "graphql" | "mcp"

/** One tool of an imported catalog. `path` is unique in the catalog; the policy address is `<namespace>.<path>`. */
export interface ToolEntry {
  readonly path: string
  readonly title: string
  readonly description?: string
  /** `provider`: an op of a first-class provider (GitHub, Linear, ...), defined by the backend catalog. */
  readonly kind: CatalogKind | "provider"
  /** OpenAPI: HTTP method in upper case. GraphQL: "query" or "mutation". MCP: absent. */
  readonly method?: string
  /** OpenAPI: path template. GraphQL: root field name. MCP: the server's tool name. */
  readonly target: string
  readonly op_class: OpClass
  readonly default_action: ToolAction
  readonly input_schema?: unknown
  readonly deprecated?: boolean
  /** OAuth scope alternatives (OR of AND sets) the operation declares. */
  readonly scopes?: ReadonlyArray<ReadonlyArray<string>>
}

/**
 * A way to authenticate to a generic API, as declared by its spec. The secret
 * itself never appears here: the host collects it and returns a `cred_…`
 * handle (README, "Credentials").
 */
export interface AuthMethod {
  readonly kind: "api_key" | "bearer" | "basic" | "headers" | "oauth2"
  readonly label: string
  /** Header names that carry a secret. */
  readonly headers?: ReadonlyArray<string>
  /** Query parameter names that carry a secret. */
  readonly query?: ReadonlyArray<string>
  readonly flow?: "authorization_code" | "client_credentials"
  readonly authorization_url?: string
  readonly token_url?: string
  readonly scopes?: ReadonlyArray<string>
}

/** The result of ingesting one spec, introspection result or MCP tool list. */
export interface Catalog {
  readonly kind: CatalogKind
  /** Policy address prefix, derived from the title or host (lower case, `_` separated). */
  readonly namespace: string
  readonly title: string
  readonly version?: string
  readonly base_url?: string
  readonly tools: ReadonlyArray<ToolEntry>
  readonly auth: ReadonlyArray<AuthMethod>
  /** Stable digest of the tool list (paths, methods, classes): changes when a refresh changes the catalog. */
  readonly digest: string
}

export const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value)

// @cmux/integrations-core: the one implementation of generic integration
// ingestion (OpenAPI 3, GraphQL introspection, MCP `tools/list`) and per-tool
// policy defaults, shared by the cmux integrations app and the backend gateway.
// The format extractors and the policy matcher are adapted from executor
// (https://github.com/UsefulSoftwareCo/executor), MIT License, Copyright (c)
// 2026 Rhys Sullivan; see NOTICE. This file is cmux code.
//
// The root export is the importer, the policy and the types. Each format
// module is a namespace (and a subpath export) because their low-level names
// overlap (`extract`).

export * from "./types.ts"
export * from "./policy.ts"
export * from "./catalog.ts"
export * as openapi from "./openapi.ts"
export * as openapiPaths from "./openapi-paths.ts"
export * as openapiAuth from "./openapi-auth.ts"
export * as graphql from "./graphql.ts"
export * as mcp from "./mcp.ts"

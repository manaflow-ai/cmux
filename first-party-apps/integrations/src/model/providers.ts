// First-class providers and generic kinds the app shows. The connection
// records themselves come from the backend (`integration.list`, owner
// ConnectionDO); this table holds only display facts and the provider ops the
// backend catalog defines (protocol integrations.ts), so per-tool policy works
// for first-class providers too.

import { defaultActionFor, type CatalogKind, type OpClass, type ToolEntry } from "@cmux/integrations-core"
import { t } from "../l10n.ts"

export type FirstClassProvider = "github" | "linear" | "slack" | "google_calendar" | "gmail"
export type ProviderId = FirstClassProvider | CatalogKind

export interface ProviderOp {
  readonly op: string
  readonly op_class: OpClass
}

export interface ProviderInfo {
  readonly id: ProviderId
  /** Product name; not translated. */
  readonly name: string
  readonly symbol: string
  readonly generic: boolean
  /** `coming`: in the spec's first providers but not built in the backend yet; shown, never connectable. */
  readonly availability: "available" | "coming"
  readonly ops: ReadonlyArray<ProviderOp>
}

export const FIRST_CLASS: ReadonlyArray<FirstClassProvider> = ["github", "linear", "slack", "google_calendar", "gmail"]
/** First-class providers the backend can connect today (`IntegrationProvider`). */
export const CONNECTABLE: ReadonlyArray<FirstClassProvider> = ["github", "linear", "slack"]
export const GENERIC: ReadonlyArray<CatalogKind> = ["openapi", "graphql", "mcp"]

const TABLE: Record<ProviderId, ProviderInfo> = {
  github: { id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", generic: false, availability: "available", ops: [{ op: "github.issue.comment", op_class: "send-external" }] },
  linear: {
    id: "linear",
    name: "Linear",
    symbol: "checklist",
    generic: false,
    availability: "available",
    ops: [
      { op: "linear.teams.list", op_class: "read" },
      { op: "linear.issue.create", op_class: "mutate-shared" }
    ]
  },
  slack: { id: "slack", name: "Slack", symbol: "number", generic: false, availability: "available", ops: [{ op: "slack.post_as_bot", op_class: "send-external" }] },
  google_calendar: {
    id: "google_calendar",
    name: "Google Calendar",
    symbol: "calendar",
    generic: false,
    availability: "coming",
    ops: [
      { op: "calendar.list", op_class: "read" },
      { op: "calendar.create", op_class: "mutate-shared" },
      { op: "calendar.respond", op_class: "send-external" }
    ]
  },
  gmail: {
    id: "gmail",
    name: "Gmail",
    symbol: "envelope",
    generic: false,
    availability: "coming",
    ops: [
      { op: "mail.draft", op_class: "mutate-own" },
      { op: "mail.send", op_class: "send-external" }
    ]
  },
  openapi: { id: "openapi", name: "OpenAPI", symbol: "curlybraces", generic: true, availability: "available", ops: [] },
  graphql: { id: "graphql", name: "GraphQL", symbol: "point.3.connected.trianglepath.dotted", generic: true, availability: "available", ops: [] },
  mcp: { id: "mcp", name: "MCP", symbol: "server.rack", generic: true, availability: "available", ops: [] }
}

const isProviderId = (v: unknown): v is ProviderId => typeof v === "string" && v in TABLE

/** Display facts of a provider id; unknown providers (a newer backend) get a neutral entry. */
export const providerInfo = (id: string): ProviderInfo => (isProviderId(id) ? TABLE[id] : { id: id as ProviderId, name: id, symbol: "puzzlepiece.extension", generic: false, availability: "available", ops: [] })

/** One line that says what connecting the provider gives agents and automations. */
export const providerBlurb = (id: string): string => {
  switch (id) {
    case "github":
      return t("provider.github.blurb", "Issues, pull requests and repository events")
    case "linear":
      return t("provider.linear.blurb", "Create issues and follow team updates")
    case "slack":
      return t("provider.slack.blurb", "Post to channels as the cmux bot")
    case "google_calendar":
      return t("provider.google_calendar.blurb", "Read events and answer invitations")
    case "gmail":
      return t("provider.gmail.blurb", "Draft and send mail with your approval")
    case "openapi":
      return t("provider.openapi.blurb", "Any REST API with an OpenAPI 3 description")
    case "graphql":
      return t("provider.graphql.blurb", "Any GraphQL endpoint, read by introspection")
    case "mcp":
      return t("provider.mcp.blurb", "A remote MCP server over Streamable HTTP")
    default:
      return ""
  }
}

/** Catalog tools of a first-class provider, built from the backend's provider ops (address = op name). */
export const builtinTools = (id: string): ToolEntry[] =>
  providerInfo(id).ops.map((o) => ({
    path: o.op.split(".").slice(1).join("."),
    title: o.op,
    kind: "provider",
    target: o.op,
    op_class: o.op_class,
    default_action: defaultActionFor(o.op_class)
  }))

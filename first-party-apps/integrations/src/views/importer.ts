// Add a generic API: paste a spec URL or JSON, see the tools it would add with
// the policy each gets by default, pick how it authenticates, then add it.

import { defaultCounts, EGRESS_LIMITS, type AuthChoice, type Catalog, type ToolEntry } from "@cmux/integrations-core"
import { t } from "../l10n.ts"
import { atLimit } from "../model/connections.ts"
import { providerInfo } from "../model/providers.ts"
import { addImported, authIndex, choicesFor, importState, setAuthIndex, submitImport, type Blocked } from "../model/importer.ts"
import { egressText, list, route } from "../model/store.ts"
import { actionLabel, actionTone } from "../model/tools.ts"
import { aboutLine, credentialKindText, header, methodBadge, noticeLine, sectionTitle, smallButton } from "./common.ts"
import { hostsLine, usageLine } from "./gallery.ts"

const PREVIEW_TOOLS = 14

/** One auth choice: the kind, plus where the secret goes when the document says so. */
const authText = (c: AuthChoice): string => {
  const kind = credentialKindText(c.kind)
  const where = [...(c.method?.headers ?? []), ...(c.method?.query ?? [])].filter((h) => h !== "Authorization")
  if (c.dynamic_registration) return t("auth.oauthDcr", "{kind} (registers cmux with the server)", { kind })
  return where.length ? t("auth.where", "{kind} in {where}", { kind, where: where.join(", ") }) : kind
}

function toolPreview(tool: ToolEntry) {
  return HStack({ spacing: 8 }, [
    methodBadge(tool.method),
    Text(tool.title).font("caption").lineLimit(1),
    Spacer(),
    Text(actionLabel(tool.default_action)).font("caption2").color(actionTone(tool.default_action))
  ]).padding({ top: 2, leading: 12, bottom: 2, trailing: 12 })
}

function authChooser(catalog: Catalog) {
  const choices = choicesFor(catalog)
  return VStack({ spacing: 0 }, [
    ...choices.map((c, i) =>
      HStack({ spacing: 8 }, [
        Icon(() => (authIndex() === i ? "largecircle.fill.circle" : "circle"))
          .font("caption")
          .color(() => (authIndex() === i ? "accent" : "tertiary")),
        Text(authText(c)).font("caption").lineLimit(1),
        Spacer(),
        c.method ? Text(t("auth.declared", "From the spec")).font("caption2").color("tertiary") : null
      ])
        .padding({ top: 3, leading: 12, bottom: 3, trailing: 12 })
        .cursor("pointer")
        .onTap(() => setAuthIndex(i))
    ),
    Text(t("auth.sheet", "cmux asks for the secret in its own secure window. This app never sees it."))
      .font("caption2")
      .color("tertiary")
      .lineLimit(2)
      .padding({ top: 2, leading: 12, bottom: 2, trailing: 12 })
  ])
}

const blockedText = (b: Blocked): string => (b.code === "policy.denied" ? t("error.policyDenied", "Your team's policy does not allow this.") : (egressText(b.code, b.host) ?? b.code))

function previewCard(catalog: Catalog, local: boolean, blocked: Blocked | null) {
  const n = defaultCounts(catalog.tools)
  const info = providerInfo(catalog.kind)
  return VStack({ spacing: 0 }, [
    HStack({ spacing: 8 }, [
      Icon(info.symbol).color("secondary"),
      VStack({ spacing: 1 }, [
        Text(`${catalog.title}${catalog.version ? ` ${catalog.version}` : ""}`).weight("semibold").lineLimit(1),
        Text(catalog.base_url ? `${info.name} · ${catalog.base_url}` : info.name)
          .font("caption")
          .color("secondary")
          .lineLimit(1)
      ]),
      Spacer()
    ]).padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
    Text(t("import.defaults", "{total} tools: {allow} allowed (reads), {ask} ask first (changes), {block} blocked (destructive)", { total: catalog.tools.length, allow: n.allow, ask: n.ask, block: n.block }))
      .font("caption")
      .color("secondary")
      .lineLimit(2)
      .padding({ top: 2, leading: 12, bottom: 4, trailing: 12 }),
    local ? Text(t("import.local", "Read on this Mac; cmux checks it again when you add it.")).font("caption2").color("tertiary").padding({ top: 0, leading: 12, bottom: 4, trailing: 12 }) : null,
    blocked ? Text(blockedText(blocked)).font("caption").color("danger").lineLimit(3).fixedSize("vertical").padding({ top: 2, leading: 12, bottom: 4, trailing: 12 }) : null,
    sectionTitle(t("import.auth", "Sign-in")),
    authChooser(catalog),
    sectionTitle(t("import.tools", "Tools")),
    ...catalog.tools.slice(0, PREVIEW_TOOLS).map(toolPreview),
    catalog.tools.length > PREVIEW_TOOLS ? Text(t("import.moreTools", "and {n} more", { n: catalog.tools.length - PREVIEW_TOOLS })).font("caption").color("tertiary").padding({ top: 2, leading: 12, bottom: 2, trailing: 12 }) : null,
    HStack({ spacing: 8 }, [
      Spacer(),
      smallButton(t("action.addForTeam", "Add for Team"), () => addImported("team")).disabled(() => !!blocked || atLimit(list())),
      smallButton(t("action.addApi", "Add API"), () => addImported("private")).disabled(() => !!blocked || atLimit(list()))
    ]).padding({ top: 10, leading: 12, bottom: 4, trailing: 12 }),
    Text(t("import.policyLater", "You can change each tool's policy after adding.")).font("caption2").color("tertiary").padding({ top: 0, leading: 12, bottom: 4, trailing: 12 })
  ])
}

/** What to paste, by the kind the user picked (MCP: a remote server's Streamable HTTP URL; stdio is not supported). */
const helpText = (): string => {
  const r = route()
  const kind = r.screen === "import" ? r.kind : undefined
  const limits = { mb: EGRESS_LIMITS.maxResponseBytes / (1024 * 1024), s: EGRESS_LIMITS.timeoutMs / 1000 }
  if (kind === "mcp") return t("import.help.mcp", "Paste the server's Streamable HTTP URL, or its tool list as JSON. Local (stdio) servers are not supported.")
  if (kind === "graphql") return t("import.help.graphql", "Paste the endpoint URL, or its introspection result as JSON.")
  return t("import.help", "Paste a spec URL or JSON (OpenAPI 3, GraphQL introspection or an MCP tool list). Public hosts only, up to {mb} MB and {s} seconds.", limits)
}

export function importView() {
  return VStack({ spacing: 0 }, [
    header(t("import.title", "Add an API"), [], true),
    noticeLine(),
    Text(() => helpText())
      .font("caption")
      .color("secondary")
      .lineLimit(3)
      .padding({ top: 0, leading: 12, bottom: 6, trailing: 12 }),
    usageLine(),
    hostsLine(),
    TextField("", { placeholder: t("import.placeholder", "Spec URL or JSON"), onSubmit: (text) => submitImport(text) }).padding({ top: 0, leading: 12, bottom: 6, trailing: 12 }),
    () => {
      const s = importState()
      switch (s.phase) {
        case "idle":
          return null
        case "loading":
          return HStack({ spacing: 6 }, [ProgressView(), Text(t("import.loading", "Reading the spec")).font("caption").color("secondary")]).padding({ top: 4, leading: 12, bottom: 4, trailing: 12 })
        case "error":
          return Text(s.text)
            .font("caption")
            .color(s.missing ? "secondary" : "danger").lineLimit(4).padding({ top: 4, leading: 12, bottom: 4, trailing: 12 })
        case "ready":
          return previewCard(s.catalog, s.local, s.blocked)
      }
    },
    aboutLine()
  ])
}

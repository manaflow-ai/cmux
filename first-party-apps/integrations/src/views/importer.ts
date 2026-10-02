// Add a generic API: paste a spec URL or JSON, see the tools it would add with
// the policy each gets by default, pick how it authenticates, then add it.

import { defaultCounts } from "../core/catalog.ts"
import type { AuthMethod, Catalog, ToolEntry } from "../core/types.ts"
import { t } from "../l10n.ts"
import { providerInfo } from "../model/providers.ts"
import { addImported, authIndex, importState, setAuthIndex, submitImport } from "../model/importer.ts"
import { actionLabel, actionTone } from "../model/tools.ts"
import { aboutLine, header, methodBadge, noticeLine, sectionTitle, smallButton } from "./common.ts"

const PREVIEW_TOOLS = 14

const authText = (m: AuthMethod): string => {
  switch (m.kind) {
    case "bearer":
      return t("auth.bearer", "Bearer token")
    case "basic":
      return t("auth.basic", "User name and password")
    case "api_key":
      return t("auth.apiKey", "API key in {where}", { where: [...(m.headers ?? []), ...(m.query ?? [])].join(", ") })
    case "headers":
      return t("auth.headers", "Custom headers: {names}", { names: [...(m.headers ?? []), ...(m.query ?? [])].join(", ") })
    case "oauth2":
      return m.flow === "client_credentials" ? t("auth.oauthClient", "OAuth client credentials") : t("auth.oauth", "Sign in with OAuth")
  }
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
  if (catalog.auth.length === 0) return Text(t("import.noAuth", "No sign-in needed")).font("caption").color("secondary").padding({ top: 2, leading: 12, bottom: 2, trailing: 12 })
  return VStack(
    { spacing: 0 },
    catalog.auth.map((m, i) =>
      HStack({ spacing: 8 }, [
        Icon(() => (authIndex() === i ? "largecircle.fill.circle" : "circle"))
          .font("caption")
          .color(() => (authIndex() === i ? "accent" : "tertiary")),
        Text(authText(m)).font("caption").lineLimit(1),
        Spacer()
      ])
        .padding({ top: 3, leading: 12, bottom: 3, trailing: 12 })
        .cursor("pointer")
        .onTap(() => setAuthIndex(i))
    )
  )
}

function previewCard(catalog: Catalog, local: boolean) {
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
    sectionTitle(t("import.auth", "Sign-in")),
    authChooser(catalog),
    sectionTitle(t("import.tools", "Tools")),
    ...catalog.tools.slice(0, PREVIEW_TOOLS).map(toolPreview),
    catalog.tools.length > PREVIEW_TOOLS ? Text(t("import.moreTools", "and {n} more", { n: catalog.tools.length - PREVIEW_TOOLS })).font("caption").color("tertiary").padding({ top: 2, leading: 12, bottom: 2, trailing: 12 }) : null,
    HStack({ spacing: 8 }, [Spacer(), smallButton(t("action.addForTeam", "Add for Team"), () => addImported("team")), smallButton(t("action.addApi", "Add API"), () => addImported("private"))]).padding({ top: 10, leading: 12, bottom: 4, trailing: 12 }),
    Text(t("import.policyLater", "You can change each tool's policy after adding.")).font("caption2").color("tertiary").padding({ top: 0, leading: 12, bottom: 4, trailing: 12 })
  ])
}

export function importView() {
  return VStack({ spacing: 0 }, [
    header(t("import.title", "Add an API"), [], true),
    noticeLine(),
    Text(t("import.help", "Paste an OpenAPI 3 URL or document, a GraphQL endpoint's introspection result, or an MCP server's tool list."))
      .font("caption")
      .color("secondary")
      .lineLimit(3)
      .padding({ top: 0, leading: 12, bottom: 6, trailing: 12 }),
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
          return previewCard(s.catalog, s.local)
      }
    },
    aboutLine()
  ])
}

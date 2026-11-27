/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
/// <reference path="./globals.d.ts" />
// Integrations: a UI and onboarding over the backend's integration model
// (Connection records owned by ConnectionDO; the gateway holds credentials).
// Lists connections with health, sharing and team policy; connects first-class
// providers; adds generic OpenAPI, GraphQL and MCP integrations whose tools get
// per-tool Allow / Ask / Block defaults from the spec. The generic import code
// is adapted from executor (MIT License, Copyright (c) 2026 Rhys Sullivan);
// see LICENSE-executor.

import * as commands from "./commands.ts"
import { detectLanguage, setLanguage } from "./l10n.ts"
import { open, reload } from "./model/store.ts"
import { sectionView } from "./views/section.ts"
import { paneView } from "./views/variants.ts"

let following = false

/** Re-read when `integration.changed` arrives on the user stream (ConnectionDO outbox through the session); no polling. One subscription per app VM. */
function follow() {
  if (following) return
  following = true
  cmux.events.on("integration.changed", () => reload())
}

/** Sidebar section "Integrations". */
export function renderSection(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  follow()
  reload()
  return sectionView((detail) => commands.openIntegrations(detail ? { connection: detail } : {}))
}

/** Pane kind `integrations`. */
export function renderPane(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  if (typeof ctx.connection === "string") open({ screen: "detail", id: ctx.connection })
  follow()
  reload()
  return paneView()
}

export const openIntegrations = commands.openIntegrations
export const connect = commands.connect
export const importApi = commands.importApi
export const cycleVariant = commands.cycleVariant

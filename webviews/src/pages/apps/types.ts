// Wire types of `cmux.apps/1` (plans/cmux-next/app-platform.md section 15). The app platform
// lead owns these ops and their Rust types (schemars, cmux-tui-core/src/apps/store.rs); this file
// is a draft that the generated client replaces after their pane-protocol merge. Field names follow
// the section 15 table and the Swift prototype (AppStoreListing, InstalledApp).

export type AppTier = "first-party" | "verified" | "unverified";

export type AppSource = "default" | "user" | "bundled" | "local";

/** The risk class of a scope (scope-classes.json). */
export type ScopeRisk = "read" | "mutate-own" | "mutate" | "network" | "integration" | "destructive";

export interface AppIconRef {
  /** A manifest path served by `cmux.apps.asset.get`; absent means the generic glyph. */
  path?: string;
}

/** One row of `cmux.apps.catalog.list`. */
export interface CatalogApp {
  id: string;
  name: string;
  description: string;
  publisher: string;
  publisher_verified: boolean;
  tier: AppTier;
  categories: string[];
  keywords?: string[];
  latest_version: string;
  install_count: number;
  icon?: AppIconRef;
  installed: boolean;
  enabled?: boolean;
  hidden?: boolean;
}

export interface CatalogListResult {
  apps: CatalogApp[];
  revision: number;
  next_cursor?: string;
}

export interface ScopeRequest {
  scope: string;
  reason: string;
  risk: ScopeRisk;
  optional: boolean;
}

export interface AppVersion {
  version: string;
  engines: string;
  published_at_ms?: number;
  yanked?: boolean;
}

/** `cmux.apps.catalog.get`. */
export interface AppDetail extends CatalogApp {
  scopes: ScopeRequest[];
  versions: AppVersion[];
  repository?: string;
  screenshots: string[];
  notices?: string[];
}

/** One row of `cmux.apps.installed.list`. */
export interface InstalledApp {
  id: string;
  name: string;
  version: string;
  enabled: boolean;
  hidden: boolean;
  sandboxed: boolean;
  source: AppSource;
  icon?: AppIconRef;
  update?: { version: string };
  /** The host's last failure for this app, when it has one. */
  failure?: string;
}

export interface InstalledListResult {
  apps: InstalledApp[];
  revision: number;
}

export interface GrantRow extends ScopeRequest {
  granted: boolean;
}

/** `cmux.apps.grants.get`. */
export interface Grants {
  app: string;
  sandboxed: boolean;
  scopes: GrantRow[];
}

export interface LogLine {
  level: "debug" | "info" | "warn" | "error";
  message: string;
  at_ms: number;
}

/** `cmux.apps.watch` event. */
export interface AppsChanged {
  revision: number;
  app?: string;
}

/** A mutation that needs a person: the Mac host confirms natively and answers with the outcome. */
export interface ConfirmedResult {
  status: "done" | "cancelled";
}

export const AppsOps = {
  catalogList: "cmux.apps.catalog.list",
  catalogGet: "cmux.apps.catalog.get",
  assetGet: "cmux.apps.asset.get",
  installedList: "cmux.apps.installed.list",
  install: "cmux.apps.install",
  uninstall: "cmux.apps.uninstall",
  set: "cmux.apps.set",
  grantsGet: "cmux.apps.grants.get",
  grantSet: "cmux.apps.grant.set",
  updatesList: "cmux.apps.updates.list",
  update: "cmux.apps.update",
  logs: "cmux.apps.logs",
  watch: "cmux.apps.watch",
  open: "cmux.apps.open",
} as const;

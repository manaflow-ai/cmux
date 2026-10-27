// Wire types of `cmux.apps/1` (plans/cmux-next/app-platform.md section 15). The app platform
// lead owns these ops and their Rust types (schemars, cmux-tui-core/src/apps/store.rs); this file
// is a draft that the generated client replaces after their pane-protocol merge. Field names follow
// the section 15 table and the Swift prototype (AppStoreListing, InstalledApp).

export type AppTier = "first-party" | "verified" | "unverified";

export type AppSource = "default" | "user" | "bundled" | "local";

/** The risk class of a scope (cmux-app-host schema/v2/scope-classes.json). */
export type ScopeRisk = "standard" | "sensitive" | "restricted";

export interface AppIconRef {
  /** The image as a `data:` URL (from `cmux.apps.asset.get`); absent means the generic glyph. */
  path?: string;
  /** The manifest path of the image in the package, which `cmux.apps.asset.get` serves. */
  asset?: string;
  /** A symbol name: the host draws cmux's own icon for it at `glyph/<symbol>` (never an SF Symbol). */
  symbol?: string;
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
  /** The owner's word: hidable, never removable (first-party apps; FIRST-PARTY-APPS). */
  hide_only?: boolean;
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

/** One thing an app puts in cmux (the manifest's `contributes`): its kind and its title. */
export interface AppContribution {
  /** `section`, `command`, `statusItem`; another kind shows as its name. */
  kind: string;
  title: string;
}

/** `cmux.apps.catalog.get`. */
export interface AppDetail extends CatalogApp {
  scopes: ScopeRequest[];
  versions: AppVersion[];
  repository?: string;
  screenshots: string[];
  notices?: string[];
  /** "What it adds" on the app's page; absent until the owner sends it. */
  contributes?: AppContribution[];
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
  /** The listing's tier; first-party apps are hidable, never removable (FIRST-PARTY-APPS). */
  tier?: AppTier;
  /** The owner's word on Hide versus Remove; wins over `tier`. */
  hide_only?: boolean;
  icon?: AppIconRef;
  update?: { version: string };
  /** The host's last failure for this app, when it has one. */
  failure?: string;
}

/** One row returned by `cmux.apps.updates.list`. The supervisor owns the versions. */
export interface AppUpdate {
  app: string;
  name?: string;
  current_version?: string;
  version: string;
  failure?: string;
}

export interface UpdatesListResult {
  updates: AppUpdate[];
  revision: number;
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

/** `cmux.apps.logs`: the last lines of the app's log ring. */
export interface WireLogs {
  app: string;
  lines: { level: LogLine["level"]; message: string; ts_ms: number }[];
}

/** `cmux.apps.asset.get`. */
export interface WireAsset {
  app: string;
  path: string;
  data_url: string;
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

/** The App Store's own app id: the store never lists itself (FIRST-PARTY-APPS). */
export const APP_STORE_ID = "cmux/app-store";

/** Home's app id: a place in cmux, not a listing (extensibility-DESIGN.md). */
export const HOME_ID = "cmux/home";

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
  grantRevoke: "cmux.apps.grant.revoke",
  hiddenSet: "cmux.apps.hidden.set",
  updatesList: "cmux.apps.updates.list",
  update: "cmux.apps.update",
  logs: "cmux.apps.logs",
  watch: "cmux.apps.watch",
} as const;

/** Open is a host verb: the page runs the host action `app.open` (cx-hnmbt.13). */
export const OPEN_ACTION = { op: "cmux.app.action.run", action: "app.open" } as const;

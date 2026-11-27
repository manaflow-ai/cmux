// An in-memory `cmux.apps` provider for the browser dev loop and tests. It is not the backend: the
// app supervisor owns installs, grants and logs (app-platform.md section 15). Install, uninstall,
// update and grant changes answer `done` here; in the app the host confirms them natively first.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { LINK_CLOSED, MockPageStreams } from "../shared/pageStreams";
import {
  AppsOps,
  OPEN_ACTION,
  type AppDetail,
  type AppsChanged,
  type GrantRow,
  type Grants,
  type InstalledApp,
  type LogLine,
} from "./types";
import type { WireDetail, WireInstalledList, WireListing, WireUpdatesList, WireIcon } from "./wire";
import { NewTabOps } from "./UseAsNewTab";
import { iconArt, screenshotArt } from "./mockArt";

import type { FeatureRow } from "./types";
export interface MockCall {
  op: string;
  /** The params without `idempotency_key`, which is recorded in `key`. */
  params: Record<string, unknown>;
  key?: string;
}

const ICON =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#6b6b6b"/><path d="M20 22h24v4H20zm0 8h24v4H20zm0 8h16v4H20z" fill="#fff"/></svg>',
  );

export class MockAppsProvider implements PageClient {
  readonly calls: MockCall[] = [];
  details: Record<string, AppDetail>;
  installed: Record<string, InstalledApp>;
  grants: Record<string, Grants>;
  /** Package files `asset.get` serves, by app and path (screenshots, icon images). */
  assets: Record<string, Record<string, string>>;
  offline = false;
  /** The daemon's built-in features (`apps.features.list`), each an existing setting. */
  features: FeatureRow[] = sampleFeatures();
  /** `experiments.appStoreFeatures`: on here so the dev loop and the gallery draw the tab. */
  featuresEnabled = true;
  /** `tabs.newTabApp`: the app New Tab shows. */
  newTabApp?: string;
  private readonly newTabWatchers = new Map<number, (data: unknown, seq: number) => void>();
  /** Errors the next call of an op throws once (a timeout, a refusal). */
  private readonly failures = new Map<string, Error>();
  /** The host's page streams (connection, dispatcher commands). */
  readonly page = new MockPageStreams();
  private revision = 1;
  private nextSub = 1;
  private readonly watchers = new Map<number, (data: unknown, seq: number) => void>();
  private readonly seqs = new Map<number, number>();
  private readonly handlers = new Map<string, PageHandler>();

  /** The owner offers the Examples shelf (developer mode, or a `cmux ext dev` app). */
  examples: boolean;

  constructor(data: ReturnType<typeof sampleApps> = sampleApps()) {
    this.details = data.details;
    this.installed = data.installed;
    this.grants = data.grants;
    this.newTabApp = data.newTabApp;
    this.assets = data.assets ?? {};
    this.examples = data.examples === true;
  }

  async call<R>(op: string, rawParams: unknown): Promise<R> {
    const { idempotency_key: key, ...params } = (rawParams ?? {}) as Record<string, unknown>;
    this.calls.push(typeof key === "string" ? { op, params, key } : { op, params });
    if (this.offline) throw pageError(LINK_CLOSED, "disconnected", true);
    const failure = this.failures.get(op);
    if (failure) {
      this.failures.delete(op);
      throw failure;
    }
    const app = typeof params.app === "string" ? params.app : "";
    switch (op) {
      case AppsOps.catalogList:
        return {
          listings: Object.values(this.details).map((detail) => this.listing(detail)),
          next_cursor: null,
          revision: this.revision,
          examples: this.examples,
        } as R;
      case AppsOps.catalogGet: {
        const detail = this.details[app];
        if (!detail) throw pageError("cmux.apps.not_found", app);
        const wire: WireDetail = {
          ...this.listing(detail),
          scopes: detail.scopes,
          versions: detail.versions,
          repository: detail.repository,
          screenshots: detail.screenshots,
          tagline: detail.tagline,
          contributes: detail.contributes,
          deploy: detail.deploy ?? null,
        };
        return wire as R;
      }
      case AppsOps.installedList: {
        const list: WireInstalledList = {
          revision: this.revision,
          apps: Object.values(this.installed).map((row) => ({
            app: row.id,
            name: row.name,
            tier: row.tier ?? "verified",
            hide_only: row.tier === "first-party",
            new_tab: row.new_tab ?? this.details[row.id]?.new_tab === true,
            state: {
              installed: true,
              enabled: row.enabled,
              hidden: row.hidden,
              sandboxed: row.sandboxed,
              source: row.source,
              version: row.version,
              update: row.update ?? null,
              failure: row.failure ?? null,
            },
            grants: [],
            instance: row.instance ?? null,
          })),
        };
        return list as R;
      }
      case AppsOps.updatesList: {
        const list: WireUpdatesList = {
          revision: this.revision,
          updates: Object.values(this.installed).flatMap((row) =>
            row.update
              ? [
                  {
                    app: row.id,
                    name: row.name,
                    current_version: row.version,
                    version: row.update.version,
                    failure: row.failure ?? null,
                  },
                ]
              : [],
          ),
        };
        return list as R;
      }
      case AppsOps.grantsGet: {
        const grants = this.grants[app];
        if (!grants) throw pageError("cmux.apps.not_installed", app);
        return grants as R;
      }
      case AppsOps.install: {
        const detail = this.details[app];
        if (!detail) throw pageError("cmux.apps.not_found", app);
        this.installed[app] = {
          id: app,
          name: detail.name,
          version: detail.latest_version,
          enabled: true,
          hidden: false,
          sandboxed: detail.tier === "unverified",
          source: "user",
          tier: detail.tier,
          icon: detail.icon,
        };
        this.grants[app] = {
          app,
          sandboxed: detail.tier === "unverified",
          scopes: detail.scopes.map((scope) => ({
            ...scope,
            granted: !scope.optional && (detail.tier !== "unverified" || scope.scope.endsWith(":read")),
          })),
        };
        return this.changed(app) as R;
      }
      case AppsOps.uninstall:
        // First-party apps are hidable, never removable (FIRST-PARTY-APPS); the owner refuses.
        if (this.installed[app]?.tier === "first-party") throw pageError("cmux.apps.first_party", app);
        delete this.installed[app];
        delete this.grants[app];
        return this.changed(app) as R;
      case AppsOps.set: {
        const row = this.installed[app];
        if (!row) throw pageError("cmux.apps.not_installed", app);
        if (typeof params.enabled === "boolean") row.enabled = params.enabled;
        if (typeof params.hidden === "boolean") row.hidden = params.hidden;
        if (typeof params.sandboxed === "boolean") {
          row.sandboxed = params.sandboxed;
          if (this.grants[app]) this.grants[app].sandboxed = params.sandboxed;
        }
        return this.changed(app) as R;
      }
      case AppsOps.featuresList:
        return this.featuresEnabled
          ? ({ revision: this.revision, enabled: true, features: structuredClone(this.features) } as R)
          : ({ revision: this.revision, enabled: false, features: [] } as R);
      case AppsOps.featuresSet: {
        const row = this.features.find((feature) => feature.id === params.id);
        if (!row) throw pageError("cmux.resource.validation_invalid", `no feature ${String(params.id)}`);
        if (row.managed) throw pageError("cmux.resource.operation_failed", "managed");
        row.on = params.on === true;
        this.revision += 1;
        return { revision: this.revision, replayed: false, changed: true } as R;
      }
      case AppsOps.hiddenSet: {
        const row = this.installed[app];
        if (!row) throw pageError("cmux.apps.not_installed", app);
        row.hidden = params.hidden === true;
        return this.changed(app) as R;
      }
      case AppsOps.grantSet:
      case AppsOps.grantRevoke: {
        const grants = this.grants[app];
        const row = grants?.scopes.find((scope) => scope.scope === params.scope);
        if (!row) throw pageError("cmux.apps.unknown_scope", String(params.scope));
        row.granted = op === AppsOps.grantSet && params.granted === true;
        return this.changed(app) as R;
      }
      case AppsOps.logs:
        return {
          app,
          lines: sampleLog(app).map((line) => ({ level: line.level, message: line.message, ts_ms: line.at_ms })),
        } as R;
      case AppsOps.assetGet: {
        const path = String(params.path);
        // An icon given as a data URL is served as the package's `icon` file.
        const url = this.assets[app]?.[path] ?? (path === ICON_ASSET ? this.details[app]?.icon?.path : undefined);
        if (!url) throw pageError("cmux.apps.asset.missing", path);
        return { app, path, data_url: url } as R;
      }
      case AppsOps.update: {
        const row = this.installed[app];
        if (row?.update) {
          row.version = row.update.version;
          delete row.update;
          delete row.failure;
        }
        return this.changed(app) as R;
      }
      case NewTabOps.get:
        return { app: this.newTabApp ?? null } as R;
      case NewTabOps.set: {
        this.newTabApp = typeof params.app === "string" ? params.app : undefined;
        const event = { app: this.newTabApp ?? null };
        for (const [sub, watcher] of this.newTabWatchers) {
          const seq = (this.seqs.get(sub) ?? 0) + 1;
          this.seqs.set(sub, seq);
          watcher(event, seq);
        }
        return event as R;
      }
      case OPEN_ACTION.op:
        return { ran: true } as R;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(
    stream: string,
    onEvent: (data: E, seq: number) => void,
    _filter?: Record<string, unknown>,
  ): Promise<() => void> {
    const pageStream = this.page.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
    if (pageStream) return pageStream;
    if (this.offline) throw pageError(LINK_CLOSED, "disconnected", true);
    const sub = this.nextSub++;
    const emit = onEvent as (data: unknown, seq: number) => void;
    if (stream === NewTabOps.changed) {
      this.newTabWatchers.set(sub, emit);
      return () => void this.newTabWatchers.delete(sub);
    }
    if (stream === AppsOps.watch) {
      this.watchers.set(sub, emit);
      return () => void this.watchers.delete(sub);
    }
    throw pageError("cmux.protocol.unknown_op", stream);
  }

  /** The next call of `op` throws `error` once. */
  failNext(op: string, error: Error): void {
    this.failures.set(op, error);
  }

  handle(op: string, handler: PageHandler): () => void {
    this.handlers.set(op, handler);
    return () => void this.handlers.delete(op);
  }

  get watcherCount(): number {
    return this.watchers.size;
  }

  /** A sample listing in the owner's wire shape. */
  private listing(detail: AppDetail): WireListing {
    const installed = this.installed[detail.id];
    return {
      app: detail.id,
      name: detail.name,
      summary: detail.description,
      tagline: detail.tagline ?? null,
      publisher: detail.publisher,
      tier: detail.tier,
      version: detail.latest_version,
      icon: wireIconOf(detail),
      categories: detail.categories,
      keywords: detail.keywords,
      hide_only: detail.tier === "first-party",
      ...(detail.commit && {
        repository: detail.repository,
        path: detail.path,
        commit: detail.commit,
        tag: detail.tag,
      }),
      new_tab: detail.new_tab === true,
      shelf: detail.shelf ?? "store",
      install: installed
        ? {
            installed: true,
            enabled: installed.enabled,
            hidden: installed.hidden,
            sandboxed: installed.sandboxed,
            source: installed.source,
            version: installed.version,
            update: installed.update ?? null,
            failure: installed.failure ?? null,
          }
        : null,
    };
  }

  private changed(app: string): { status: "done" } {
    const event: AppsChanged = { revision: ++this.revision, app };
    for (const [sub, watcher] of this.watchers) {
      const seq = (this.seqs.get(sub) ?? 0) + 1;
      this.seqs.set(sub, seq);
      watcher(event, seq);
    }
    return { status: "done" };
  }
}

/** The package path a sample's data-URL icon is served at. */
const ICON_ASSET = "assets/icon.svg";

/** A sample's icon on the wire: a package image (served by `asset.get`), a host symbol, or none. */
function wireIconOf(detail: AppDetail): WireIcon {
  if (detail.icon?.asset) return { asset: detail.icon.asset };
  if (detail.icon?.path) return { asset: ICON_ASSET };
  return detail.icon?.symbol ? { symbol: detail.icon.symbol } : null;
}

function sampleLog(app: string): LogLine[] {
  return [
    { level: "info", message: `${app} started`, at_ms: 1 },
    { level: "warn", message: "rate limited, retrying on the next event", at_ms: 2 },
  ];
}

function grant(scope: string, reason: string, risk: GrantRow["risk"], optional = false, granted = !optional): GrantRow {
  return { scope, reason, risk, optional, granted };
}

/** Bundled-style sample catalog for the dev loop: first party, verified, unverified, local. */
export function sampleApps(): {
  details: Record<string, AppDetail>;
  installed: Record<string, InstalledApp>;
  grants: Record<string, Grants>;
  /** The app New Tab shows (`tabs.newTabApp`), when one is set. */
  newTabApp?: string;
  /** The owner offers the Examples shelf. */
  examples?: boolean;
  /** Package files by app and path. */
  assets?: Record<string, Record<string, string>>;
} {
  const base = { install_count: 0, installed: false, screenshots: [] as string[], icon: { path: ICON } };
  const details: Record<string, AppDetail> = {
    "cmux.github-prs": {
      ...base,
      id: "cmux.github-prs",
      name: "GitHub PRs",
      description: "Pull requests that need you, in the sidebar.",
      publisher: "cmux",
      publisher_verified: true,
      tier: "first-party",
      categories: ["sidebar", "git"],
      keywords: ["pull request", "review"],
      latest_version: "1.2.0",
      install_count: 1200,
      scopes: [
        { scope: "net:api.github.com", reason: "Reads your pull requests.", risk: "standard", optional: false },
        { scope: "workspace:read", reason: "Matches pull requests to workspaces.", risk: "standard", optional: false },
      ],
      versions: [
        { version: "1.2.0", engines: "^1.0.0" },
        { version: "1.1.0", engines: "^1.0.0" },
      ],
      repository: "https://github.com/manaflow-ai/cmux-apps",
      tagline: "Pull requests that need you, in the sidebar",
      screenshots: ["screenshots/1.svg"],
      contributes: [
        { kind: "section", title: "Pull Requests" },
        { kind: "command", title: "Open Pull Request" },
      ],
    },
    "cmux.coderouter": {
      ...base,
      id: "cmux.coderouter",
      name: "CodeRouter",
      description: "Route Claude and Codex through your team's accounts.",
      publisher: "cmux",
      publisher_verified: true,
      tier: "first-party",
      categories: ["agents"],
      latest_version: "0.4.0",
      scopes: [
        { scope: "integration:coderouter", reason: "Connects your accounts.", risk: "sensitive", optional: false },
      ],
      versions: [{ version: "0.4.0", engines: "^1.0.0" }],
    },
    "acme.caffeinate": {
      ...base,
      id: "acme.caffeinate",
      name: "Caffeinate",
      description: "Keeps the Mac awake while an agent works.",
      publisher: "Acme",
      publisher_verified: true,
      tier: "verified",
      categories: ["productivity"],
      latest_version: "2.0.1",
      scopes: [
        {
          scope: "power:write",
          reason: "Holds a power assertion bound to the agent's terminal.",
          risk: "standard",
          optional: false,
        },
        {
          scope: "notifications:write",
          reason: "Says when it lets the Mac sleep.",
          risk: "standard",
          optional: true,
        },
      ],
      versions: [{ version: "2.0.1", engines: "^1.0.0" }],
    },
    "someone.weather": {
      ...base,
      id: "someone.weather",
      name: "Weather Status",
      description: "The weather in the status bar.",
      publisher: "someone",
      publisher_verified: false,
      tier: "unverified",
      categories: ["fun"],
      latest_version: "0.1.0",
      scopes: [
        { scope: "net:api.weather.example", reason: "Fetches the forecast.", risk: "standard", optional: false },
      ],
      versions: [{ version: "0.1.0", engines: "^1.0.0" }],
    },
    // The store itself: installed and first party; the page never lists it (FIRST-PARTY-APPS).
    "cmux/app-store": {
      ...base,
      id: "cmux/app-store",
      name: "App Store",
      description: "Find and manage cmux apps.",
      publisher: "cmux",
      publisher_verified: true,
      tier: "first-party",
      categories: ["productivity"],
      latest_version: "1.0.0",
      scopes: [],
      versions: [{ version: "1.0.0", engines: "^1.0.0" }],
    },
  };
  details["cmux.github-prs"].installed = true;
  details["cmux/app-store"].installed = true;
  const installed: Record<string, InstalledApp> = {
    "cmux.github-prs": {
      id: "cmux.github-prs",
      name: "GitHub PRs",
      version: "1.1.0",
      enabled: true,
      hidden: false,
      sandboxed: false,
      source: "default",
      tier: "first-party",
      icon: { path: ICON },
      update: { version: "1.2.0" },
    },
    "cmux/app-store": {
      id: "cmux/app-store",
      name: "App Store",
      version: "1.0.0",
      enabled: true,
      hidden: false,
      sandboxed: false,
      source: "default",
      tier: "first-party",
    },
  };
  const grants: Record<string, Grants> = {
    "cmux.github-prs": {
      app: "cmux.github-prs",
      sandboxed: false,
      scopes: [
        grant("net:api.github.com", "Reads your pull requests.", "standard"),
        grant("workspace:read", "Matches pull requests to workspaces.", "standard"),
      ],
    },
  };
  const assets = {
    "cmux.github-prs": {
      "screenshots/1.svg": screenshotArt({
        title: "Pull Requests",
        subtitle: "3 need you",
        accent: "#22c55e",
        rows: [
          { title: "Fix the flaky upload test", detail: "#412 · review requested", status: "Approved", tone: "ok" },
          { title: "Faster workspace switch", detail: "#418 · yours", status: "1 failing", tone: "bad" },
        ],
      }),
    },
  };
  return { details, installed, grants, assets };
}

type SampleData = ReturnType<typeof sampleApps>;

/** A store listing for the samples below: first-party unless `tier` says otherwise. */
function storeApp(
  fields: Pick<AppDetail, "id" | "name" | "description" | "categories"> & Partial<AppDetail>,
): AppDetail {
  return {
    publisher: "cmux",
    publisher_verified: true,
    tier: "first-party",
    latest_version: "1.0.0",
    install_count: 0,
    installed: false,
    shelf: "store",
    scopes: [],
    versions: [{ version: fields.latest_version ?? "1.0.0", engines: "^1.0" }],
    repository: "https://github.com/manaflow-ai/cmux",
    screenshots: [],
    ...fields,
  };
}

/** Screenshots of a sample app as package paths, and the files `asset.get` serves for them. */
function shots(images: string[]): { screenshots: string[]; files: Record<string, string> } {
  const screenshots = images.map((_, index) => `screenshots/${index + 1}.svg`);
  return { screenshots, files: Object.fromEntries(screenshots.map((path, index) => [path, images[index]!])) };
}

/**
 * The store as everyone sees it: cmux's first-party Cloud and CodeRouter, with the taglines,
 * places and permissions of their manifests (first-party-apps/{cloud,coderouter}) and screenshots.
 */
export function storeApps(): SampleData {
  const cloudShots = shots([
    screenshotArt({
      title: "Cloud",
      subtitle: "3 machines · 2 running",
      accent: "#3b82f6",
      cards: [
        { label: "Running", value: "2" },
        { label: "This month", value: "41 h" },
        { label: "Snapshots", value: "6" },
      ],
      rows: [
        { title: "dev-box", detail: "8 vCPU · 32 GB · us-east", status: "Running", tone: "ok" },
        { title: "build-runner", detail: "16 vCPU · 64 GB · us-east", status: "Running", tone: "ok" },
        { title: "staging", detail: "4 vCPU · 16 GB · eu-west", status: "Paused", tone: "idle" },
      ],
    }),
    screenshotArt({
      title: "Snapshots",
      subtitle: "Restore a machine to any point",
      accent: "#3b82f6",
      rows: [
        { title: "Before the dependency upgrade", detail: "dev-box · today 09:12", status: "Ready", tone: "ok" },
        { title: "Clean build cache", detail: "build-runner · yesterday", status: "Ready", tone: "ok" },
        { title: "Release candidate", detail: "staging · 3 days ago", status: "Ready", tone: "ok" },
        { title: "Nightly", detail: "dev-box · in progress", status: "Saving", tone: "warn" },
      ],
    }),
    screenshotArt({
      title: "New machine",
      subtitle: "Pick a size; you can change it later",
      accent: "#3b82f6",
      cards: [
        { label: "Small", value: "4 vCPU" },
        { label: "Medium", value: "8 vCPU" },
        { label: "Large", value: "16 vCPU" },
      ],
      rows: [
        { title: "Region", detail: "Closest to you: us-east" },
        { title: "Stop when idle", detail: "After 30 minutes without work", status: "On", tone: "ok" },
      ],
    }),
  ]);
  const routerShots = shots([
    screenshotArt({
      title: "CodeRouter",
      subtitle: "Healthy · 3 accounts connected",
      accent: "#a855f7",
      cards: [
        { label: "Requests today", value: "1,284" },
        { label: "Spend today", value: "$12.40" },
        { label: "Failovers", value: "3" },
      ],
      chart: [12, 18, 9, 22, 30, 26, 34, 28, 40, 36, 44, 38, 30, 46],
    }),
    screenshotArt({
      title: "Accounts",
      subtitle: "Shared with your team",
      accent: "#a855f7",
      rows: [
        { title: "Claude · team", detail: "Used first", status: "Healthy", tone: "ok" },
        { title: "Codex · pro", detail: "Used when the first is busy", status: "Healthy", tone: "ok" },
        { title: "OpenRouter · API key", detail: "Last resort", status: "Low credit", tone: "warn" },
      ],
    }),
  ]);
  const details: Record<string, AppDetail> = {
    "cmux/cloud": storeApp({
      id: "cmux/cloud",
      name: "Cloud",
      tagline: "Start, pause and connect to your Cloud machines",
      description:
        "Create, start, pause, resize and delete your cmux Cloud machines, and connect to them from cmux. Take and restore snapshots, forward a machine's ports to this Mac, and see your plan and usage. Your sign-in stays with cmux; this app never sees it.",
      categories: ["cloud", "developer-tools"],
      icon: { path: iconArt("cloud", "#60a5fa", "#2563eb") },
      install_count: 4200,
      latest_version: "1.4.0",
      screenshots: cloudShots.screenshots,
      contributes: [
        { kind: "pane", title: "Cloud" },
        { kind: "command", title: "New Cloud Machine" },
        { kind: "command", title: "Connect to Cloud Machine" },
      ],
      scopes: [
        {
          scope: "cloud:read",
          reason: "See your Cloud machines and their status, your snapshots, and your plan and usage.",
          risk: "standard",
          optional: false,
        },
        {
          scope: "cloud:write",
          reason:
            "Create, start, pause, resize and delete your Cloud machines and snapshots, and forward their ports to this Mac, when you or an agent you allowed asks. Deleting always needs your OK.",
          risk: "sensitive",
          optional: false,
        },
        {
          scope: "fs:write",
          reason:
            "Create and change files on your Cloud machines. Deleting a file, or copying files between a machine and this Mac, always needs your OK.",
          risk: "sensitive",
          optional: false,
        },
        {
          scope: "terminal:backend",
          reason: "Open terminals on your Cloud machines.",
          risk: "restricted",
          optional: true,
        },
      ],
    }),
    "cmux/coderouter": storeApp({
      id: "cmux/coderouter",
      name: "CodeRouter",
      tagline: "Connect your model accounts and route your agents through CodeRouter",
      description:
        "Set up CodeRouter, the cmux model router, in a few steps: connect your provider accounts, share them with your team and route your agents through it. See health, usage, spend and failover order at a glance, create API keys and send a test request. Your keys and sign-ins stay with cmux; this app never sees them.",
      categories: ["agents", "cloud", "monitoring"],
      icon: { path: iconArt("router", "#c084fc", "#7c3aed") },
      install_count: 3100,
      latest_version: "0.4.0",
      screenshots: routerShots.screenshots,
      contributes: [
        { kind: "section", title: "CodeRouter" },
        { kind: "statusItem", title: "CodeRouter Health" },
        { kind: "pane", title: "CodeRouter" },
        { kind: "command", title: "Connect Account to CodeRouter" },
        { kind: "command", title: "Test CodeRouter" },
      ],
      scopes: [
        {
          scope: "coderouter:read",
          reason:
            "See whether CodeRouter is healthy, which accounts are connected, the names of your API keys, your usage and the failover order. It never sees a key or token.",
          risk: "standard",
          optional: false,
        },
        {
          scope: "coderouter:write",
          reason:
            "Ask cmux to connect, share or remove an account and to send your agents through CodeRouter. cmux asks you first and keeps the secret.",
          risk: "sensitive",
          optional: false,
        },
        {
          scope: "actions:run",
          reason: "Open the Accounts screen and sign-in windows, and start a provider's own login when you click.",
          risk: "standard",
          optional: false,
        },
        {
          scope: "coderouter:execute",
          reason: "Send one tiny test prompt through CodeRouter when you click Test. It uses a few tokens.",
          risk: "standard",
          optional: true,
        },
      ],
    }),
  };
  // Both ship with cmux: installed from the start, CodeRouter hidden until the person shows it
  // (its manifest's `hiddenByDefault`), so the action is Show, never Install.
  details["cmux/cloud"]!.installed = true;
  details["cmux/coderouter"]!.installed = true;
  details["cmux/coderouter"]!.hidden = true;
  const shipped = (id: string, name: string, version: string, hidden: boolean): InstalledApp => ({
    id,
    name,
    version,
    enabled: true,
    hidden,
    sandboxed: false,
    source: "default",
    tier: "first-party",
  });
  return {
    details,
    installed: {
      "cmux/cloud": shipped("cmux/cloud", "Cloud", "1.4.0", false),
      "cmux/coderouter": shipped("cmux/coderouter", "CodeRouter", "0.4.0", true),
    },
    grants: {},
    assets: { "cmux/cloud": cloudShots.files, "cmux/coderouter": routerShots.files },
  };
}

/**
 * The store with a dozen apps (the widget apps another lane adds): Cloud and CodeRouter, ten
 * widgets in four categories, and two listings Discover must never show (no description; failed).
 */
export function manyStoreApps(): SampleData {
  const data = storeApps();
  const widget = (
    id: string,
    name: string,
    tagline: string,
    description: string,
    categories: string[],
    icon: [string, string, string],
    contributes: AppDetail["contributes"],
    extra: Partial<AppDetail> = {},
  ) =>
    storeApp({
      id: `cmux/${id}`,
      name,
      tagline,
      description,
      categories,
      icon: { path: iconArt(...icon) },
      contributes,
      ...extra,
    });
  const widgets = [
    widget(
      "usage",
      "Usage",
      "See tokens, cost and rate-limit windows for every agent session",
      "Tokens, cost and rate-limit windows for every agent session and account. It warns before a window runs out and says which session is spending it.",
      ["agents", "monitoring"],
      ["gauge", "#facc15", "#ca8a04"],
      [
        { kind: "sidebarWidget", title: "Usage" },
        { kind: "newTab", title: "Usage" },
      ],
      {
        install_count: 2400,
        scopes: [
          {
            scope: "sessions:read",
            reason: "Token counts each agent reports per turn.",
            risk: "standard",
            optional: false,
          },
        ],
      },
    ),
    widget(
      "pr-radar",
      "PR Radar",
      "Your open pull requests with CI, review and merge state in one list",
      "Your open pull requests, and the ones your agents opened, with CI, review and merge state in one list. Click a red check and its failing log opens beside the chat.",
      ["git", "developer-tools"],
      ["radar", "#4ade80", "#16a34a"],
      [
        { kind: "sidebarWidget", title: "PR Radar" },
        { kind: "newTab", title: "Needs you" },
        { kind: "command", title: "Open Failing Check" },
      ],
      { install_count: 1900 },
    ),
    widget(
      "world-clock",
      "World Clock",
      "The time where your team is, on New Tab",
      "Clocks for the cities you pick, on the New Tab page. Hover a clock to see the date there.",
      ["productivity"],
      ["clock", "#94a3b8", "#475569"],
      [{ kind: "newTab", title: "World Clock" }],
      { install_count: 800 },
    ),
    widget(
      "weather",
      "Weather",
      "Today's weather in the title bar",
      "The temperature and sky for where you are, in the title bar. Click it for the next hours.",
      ["fun"],
      ["sun", "#fb923c", "#ea580c"],
      [{ kind: "statusItem", title: "Weather" }],
      {
        install_count: 640,
        scopes: [
          { scope: "net:api.weather.example", reason: "Fetches the forecast.", risk: "standard", optional: false },
        ],
      },
    ),
    widget(
      "recent-prs",
      "Recent PRs",
      "Pull requests you touched this week, a click away",
      "The pull requests you opened, reviewed or commented on this week, newest first, in the sidebar.",
      ["git"],
      ["pr", "#38bdf8", "#0284c7"],
      [{ kind: "sidebarWidget", title: "Recent PRs" }],
      { install_count: 720 },
    ),
    widget(
      "workspace-notes",
      "Workspace Notes",
      "Keep a note with each workspace",
      "A short note that stays with each workspace: what you were doing, what is next. It shows in Session Info.",
      ["productivity"],
      ["note", "#fbbf24", "#d97706"],
      [{ kind: "sessionInfo", title: "Notes" }],
      { install_count: 530 },
    ),
    widget(
      "activity",
      "Activity",
      "What your agents did today, as a timeline",
      "Every agent turn, command and file change today, grouped by workspace, on New Tab.",
      ["agents"],
      ["pulse", "#f472b6", "#db2777"],
      [{ kind: "newTab", title: "Activity" }],
      { install_count: 470 },
    ),
    widget(
      "standup",
      "Standup",
      "Jot what you did, read it back at standup",
      "Write a line when you finish something; at standup, read the list back and clear it.",
      ["productivity"],
      ["list", "#a3e635", "#65a30d"],
      [{ kind: "command", title: "Add to Standup" }],
      { install_count: 300 },
    ),
    widget(
      "ports",
      "Ports",
      "See what is listening in each workspace",
      "Ports open in each workspace, with the program behind them. Click one to open it in a browser tab.",
      ["developer-tools"],
      ["plug", "#2dd4bf", "#0d9488"],
      [{ kind: "sidebarWidget", title: "Ports" }],
      { install_count: 280 },
    ),
    widget(
      "focus-timer",
      "Focus Timer",
      "A focus timer in the title bar that mutes notifications",
      "Start a 25 minute focus block from the title bar. Notifications wait until it ends.",
      ["productivity", "fun"],
      ["timer", "#f87171", "#dc2626"],
      [{ kind: "statusItem", title: "Focus Timer" }],
      { install_count: 260 },
    ),
    widget(
      "agent-pet",
      "Agent Pet",
      "A small pet that reacts to what your agents do",
      "A pet in the sidebar that wakes up when an agent starts and cheers when it finishes.",
      ["fun"],
      ["paw", "#fdba74", "#f97316"],
      [{ kind: "sidebarWidget", title: "Agent Pet" }],
      { install_count: 220 },
    ),
    // Never on Discover: a listing with no description, and an app the host failed to load.
    widget("untitled", "Untitled Widget", "", "", ["productivity"], ["list", "#71717a", "#3f3f46"], []),
    widget(
      "broken",
      "Broken Widget",
      "Fails to load",
      "This app failed to load.",
      ["productivity"],
      ["list", "#71717a", "#3f3f46"],
      [],
      { installed: true },
    ),
  ];
  for (const app of widgets) data.details[app.id] = app;
  const usageShots = shots([
    screenshotArt({
      title: "Usage",
      subtitle: "4 accounts · 11 live sessions",
      accent: "#facc15",
      cards: [
        { label: "Claude · team", value: "78%" },
        { label: "Codex · pro", value: "31%" },
        { label: "OpenRouter", value: "$18.40" },
      ],
      chart: [4, 6, 9, 7, 12, 15, 11, 18, 22, 19, 24, 28],
    }),
  ]);
  const radarShots = shots([
    screenshotArt({
      title: "PR Radar",
      subtitle: "12 open · 3 need you",
      accent: "#22c55e",
      rows: [
        { title: "One-click install from the App Store", detail: "#1024 · you", status: "Ready to land", tone: "ok" },
        { title: "Sidebar keeps its tonal step", detail: "#1031 · agent", status: "1 failing", tone: "bad" },
        { title: "Resume a hibernated chat", detail: "#1040 · you", status: "Approved", tone: "ok" },
        { title: "Ports: list listeners per workspace", detail: "#1052 · agent", status: "Queued", tone: "warn" },
      ],
    }),
  ]);
  data.details["cmux/usage"]!.screenshots = usageShots.screenshots;
  data.details["cmux/pr-radar"]!.screenshots = radarShots.screenshots;
  data.assets = { ...data.assets, "cmux/usage": usageShots.files, "cmux/pr-radar": radarShots.files };
  data.installed["cmux/broken"] = {
    id: "cmux/broken",
    name: "Broken Widget",
    version: "1.0.0",
    enabled: true,
    hidden: false,
    sandboxed: false,
    source: "default",
    tier: "first-party",
    failure: "The app failed to start.",
  };
  return data;
}

const feature = (
  id: string,
  group: string,
  key: string,
  title: string,
  on = false,
  extra: Partial<FeatureRow> = {},
): FeatureRow => ({
  id,
  group,
  key,
  kind: "toggle",
  on,
  default_on: false,
  managed: false,
  title: { text: title },
  ...extra,
});

/** Public-safe sample features, the daemon's groups in its order (server/app_features.rs). */
export function sampleFeatures(): FeatureRow[] {
  return [
    feature(
      "backgrounds.shufflePaintings",
      "Backgrounds",
      "appearance.background",
      "Background: Shuffle Paintings",
      false,
      {
        kind: "choice",
      },
    ),
    feature("backgrounds.glass", "Backgrounds", "appearance.backgroundBlur", "Material: Glass", true, {
      kind: "choice",
    }),
    feature("chief.pet", "Chief", "home.chiefPetEnabled", "Show Chief Pet", true, {
      summary: { text: "A small companion on Chief's home" },
    }),
    feature("chief.channels", "Chief", "home.channelsEnabled", "Channels"),
    feature("chief.suggestedTasks", "Chief", "sessions.promptSuggestions", "Suggested Tasks", true, {
      default_on: true,
    }),
    feature("media.newTabNowPlaying", "Music", "tabs.newTabNowPlaying", "Show Now Playing on New Tab"),
    feature("media.sidebar", "Music", "sidebar.nowPlaying.enabled", "Now Playing in Sidebar"),
    feature("editor.minimap", "Editor", "editor.minimap.enabled", "Minimap"),
    feature("browser.bookmarksBar", "Browser", "browser.showBookmarksBar", "Show Bookmarks Bar", false, {
      managed: true,
    }),
    feature("labs.liveTree", "Labs", "labs.liveTree", "Live Tree"),
    feature("labs.voiceRoom", "Labs", "labs.voiceRoom", "Voice Room"),
    feature("experiments.composerV2", "Experiments", "experiments.composerV2", "Composer V2", true),
    feature("experiments.toastsV2", "Experiments", "experiments.toastsV2", "Toasts V2"),
  ];
}

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
  RegistryOps,
  SIGNED_OUT,
  type RegistryListing,
  type RegistryMe,
  type RegistrySubmission,
  type ReviewSubmission,
} from "./types";
import type { WireDetail, WireInstalledList, WireListing, WireUpdatesList } from "./wire";

/** The community registry the mock answers `cmux.registry.*` from; absent, those ops are unknown. */
export interface MockRegistry {
  me: RegistryMe;
  listings: RegistryListing[];
  submissions: RegistrySubmission[];
  queue: ReviewSubmission[];
  /** File contents by submission id, then path, as base64. */
  files: Record<string, Record<string, string>>;
  /** The catalog row `cmux.registry.get` adds for a listing (the daemon's reload in the app). */
  bundles: Record<string, AppDetail>;
}

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
  registry?: MockRegistry;
  offline = false;
  /** Errors the next call of an op throws once (a timeout, a refusal). */
  private readonly failures = new Map<string, Error>();
  /** The host's page streams (connection, dispatcher commands). */
  readonly page = new MockPageStreams();
  private revision = 1;
  private nextSub = 1;
  private readonly watchers = new Map<number, (data: unknown, seq: number) => void>();
  private readonly seqs = new Map<number, number>();
  private readonly handlers = new Map<string, PageHandler>();

  constructor(data: ReturnType<typeof sampleApps> & { registry?: MockRegistry } = sampleApps()) {
    this.details = data.details;
    this.installed = data.installed;
    this.grants = data.grants;
    this.registry = data.registry;
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
    if (op.startsWith("cmux.registry.")) return this.registryCall(op, params) as R;
    switch (op) {
      case AppsOps.catalogList:
        return {
          listings: Object.values(this.details).map((detail) => this.listing(detail)),
          next_cursor: null,
          revision: this.revision,
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
      case AppsOps.assetGet:
        throw pageError("cmux.apps.asset.missing", String(params.path));
      case AppsOps.update: {
        const row = this.installed[app];
        if (row?.update) {
          row.version = row.update.version;
          delete row.update;
          delete row.failure;
        }
        return this.changed(app) as R;
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
    if (stream === AppsOps.watch) {
      this.watchers.set(sub, emit);
      return () => void this.watchers.delete(sub);
    }
    throw pageError("cmux.protocol.unknown_op", stream);
  }

  /** `cmux.registry.*` as the Mac answers it; the native sheets answer yes here. */
  private registryCall(op: string, params: Record<string, unknown>): unknown {
    const registry = this.registry;
    if (!registry) throw pageError("cmux.protocol.unknown_op", op);
    const signedIn = () => {
      if (!registry.me.signedIn) throw pageError(SIGNED_OUT, "Sign in to cmux Cloud.");
    };
    const reviewer = () => {
      signedIn();
      if (!registry.me.reviewer) throw pageError("cloud.not_found", "Not found.");
    };
    const id = typeof params.id === "string" ? params.id : "";
    switch (op) {
      case RegistryOps.me:
        return registry.me;
      case RegistryOps.listings:
        return { listings: registry.listings };
      case RegistryOps.submissions:
        signedIn();
        return { submissions: registry.submissions };
      case RegistryOps.submit: {
        signedIn();
        const app = String(params.app ?? "");
        const name = app.replace(/^local\//, "");
        const submission: RegistrySubmission = {
          id: `sub_${registry.submissions.length + 1}`,
          app: `${String(params.publisher)}/${name}`,
          version: this.installed[app]?.version ?? "0.1.0",
          status: "pending",
          submitted_at: "2026-01-02T10:00:00Z",
        };
        registry.submissions = [submission, ...registry.submissions];
        return { submission };
      }
      case RegistryOps.reviewQueue:
        reviewer();
        return { submissions: registry.queue };
      case RegistryOps.reviewFile: {
        reviewer();
        const path = String(params.path ?? "");
        const base64 = registry.files[id]?.[path];
        if (base64 === undefined) throw pageError("cloud.not_found", path);
        return { path, base64 };
      }
      case RegistryOps.reviewDecide: {
        reviewer();
        const item = registry.queue.find((row) => row.id === id);
        if (!item) throw pageError("cloud.not_found", id);
        const reason = String(params.reason ?? "");
        if (params.decision === "reject" && (reason.length < 8 || reason.length > 500))
          throw pageError("cloud.invalid", "A reason needs 8 to 500 characters.");
        registry.queue = registry.queue.filter((row) => row.id !== id);
        return { submission: { ...item, status: params.decision === "approve" ? "approved" : "rejected", reason } };
      }
      case RegistryOps.get: {
        const app = String(params.app ?? "");
        const bundle = registry.bundles[app];
        if (!bundle) throw pageError("cloud.not_found", app);
        this.details[app] = structuredClone(bundle);
        this.changed(app);
        return { app, version: params.version };
      }
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
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
      publisher: detail.publisher,
      tier: detail.tier,
      version: detail.latest_version,
      icon: null,
      categories: detail.categories,
      keywords: detail.keywords,
      hide_only: detail.tier === "first-party",
      install: installed
        ? {
            installed: true,
            enabled: installed.enabled,
            hidden: installed.hidden,
            sandboxed: installed.sandboxed,
            source: installed.source,
            version: installed.version,
            update: installed.update ?? null,
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
      screenshots: [ICON],
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
  return { details, installed, grants };
}

const encode = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));

/** A public-safe sample registry: two approved listings, submissions in each state, one pending review. */
export function sampleRegistry(
  me: RegistryMe = { signedIn: true, user: "user_sample", reviewer: true, publishers: ["sample-studio"] },
): MockRegistry {
  const boardManifest = {
    manifestVersion: 2,
    id: "sample-studio/workspace-board",
    name: "Workspace Board",
    version: "0.2.0",
    description: "Every workspace and its terminals; send a command to one.",
    icon: { symbol: "square.grid.2x2" },
    scopes: { "workspace:read": "List your workspaces.", "terminal:read": "List the terminals of each workspace." },
    optionalScopes: { "terminal:execute": "Send a command you type to a terminal." },
  };
  const board: AppDetail = {
    id: "sample-studio/workspace-board",
    name: "Workspace Board",
    description: "Every workspace and its terminals; send a command to one.",
    publisher: "sample-studio",
    publisher_verified: false,
    tier: "unverified",
    categories: ["productivity"],
    latest_version: "0.2.0",
    install_count: 0,
    installed: false,
    screenshots: [],
    icon: { symbol: "square.grid.2x2" },
    scopes: [
      { scope: "workspace:read", reason: "List your workspaces.", risk: "standard", optional: false },
      { scope: "terminal:read", reason: "List the terminals of each workspace.", risk: "standard", optional: false },
      {
        scope: "terminal:execute",
        reason: "Send a command you type to a terminal.",
        risk: "sensitive",
        optional: true,
      },
    ],
    versions: [{ version: "0.2.0", engines: "^2.0" }],
  };
  return {
    me,
    listings: [
      {
        app: board.id,
        name: board.name,
        description: board.description,
        publisher: board.publisher,
        version: "0.2.0",
        sha256: "0".repeat(64),
        size: 4096,
        approved_at: "2026-01-01T12:00:00Z",
        manifest: boardManifest,
      },
      {
        app: "pixel-works/focus-timer",
        name: "Focus Timer",
        description: "A quiet timer pane for focused sessions.",
        publisher: "pixel-works",
        version: "1.0.0",
        sha256: "1".repeat(64),
        size: 2048,
        approved_at: "2026-01-01T09:00:00Z",
        manifest: { manifestVersion: 2, name: "Focus Timer", version: "1.0.0", scopes: {} },
      },
    ],
    submissions: [
      {
        id: "sub_3",
        app: "sample-studio/notes-pane",
        version: "0.1.0",
        status: "pending",
        submitted_at: "2026-01-03T10:00:00Z",
      },
      {
        id: "sub_2",
        app: "sample-studio/workspace-board",
        version: "0.2.0",
        status: "approved",
        submitted_at: "2026-01-01T08:00:00Z",
        decided_at: "2026-01-01T12:00:00Z",
      },
      {
        id: "sub_1",
        app: "sample-studio/workspace-board",
        version: "0.1.0",
        status: "rejected",
        reason: "The pane asks for terminal:execute but never explains it in the UI.",
        submitted_at: "2025-12-30T08:00:00Z",
        decided_at: "2025-12-31T08:00:00Z",
      },
    ],
    queue: [
      {
        id: "sub_9",
        app: "pixel-works/clock-pane",
        version: "0.3.0",
        submitted_at: "2026-01-04T15:30:00Z",
        submitter: { user: "user_pixel", email: "dev@example.com" },
        manifest: {
          manifestVersion: 2,
          id: "pixel-works/clock-pane",
          name: "Clock Pane",
          version: "0.3.0",
          description: "A large clock for a spare pane.",
          scopes: { "workspace:read": "Shows the clock beside the active workspace name." },
        },
        files: [
          { path: "cmux-app.json", size: 310 },
          { path: "web/index.html", size: 182 },
          { path: "web/clock.js", size: 96 },
          { path: "web/icon.png", size: 4 },
        ],
        notes: "First release; the clock follows the system time zone.",
      },
    ],
    files: {
      sub_9: {
        "cmux-app.json": encode('{\n  "manifestVersion": 2,\n  "id": "pixel-works/clock-pane"\n}\n'),
        "web/index.html": encode('<!doctype html>\n<title>Clock</title>\n<script src="clock.js"></script>\n'),
        "web/clock.js": encode(
          "setInterval(() => {\n  document.body.textContent = new Date().toLocaleTimeString();\n}, 1000);\n",
        ),
        "web/icon.png": btoa(String.fromCharCode(0x89, 0x50, 0x4e, 0x47, 0, 0)),
      },
    },
    bundles: { [board.id]: board },
  };
}

/** A local app being developed, installed from its folder (`local/<name>`). */
export function sampleLocalApp(): InstalledApp {
  return {
    id: "local/notes-pane",
    name: "Notes Pane",
    version: "0.1.0",
    enabled: true,
    hidden: false,
    sandboxed: true,
    source: "local",
    tier: "unverified",
  };
}

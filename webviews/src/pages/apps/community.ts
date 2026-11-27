// The App Store's Community section on the page side: community extensions and setups from the
// public registry, read through the owner's `catalog.list {source: "community"}` and
// `catalog.get {source: "community", ref}` (cmux-tui-core apps/community.rs). The owner answers
// from its cached index and refreshes it in the background; `apps-changed` follows a refresh, and
// an open Community section re-reads on it. Installing a row is `apps.install {app: install_app}`
// through the page's own install path (AppsStore.install), so the host's consent card always shows.
//
// The production registry may still be empty or unreachable. Then the owner answers no rows or an
// `error`, and the section shows a calm empty state with a link to the website, never an error.
import { isPageError, type PageClient } from "../shared/pageClient";
import { AppsOps, type AppsChanged } from "./types";

export type CommunityKind = "extension" | "setup" | "theme" | "snippet";
export type CommunitySort = "featured" | "downloads" | "updated" | "stars" | "name";

/** Every listing kind the registry sends (the row's `kind`), in the order the filters show them. */
export const COMMUNITY_KINDS: readonly CommunityKind[] = ["extension", "setup", "theme", "snippet"];
/** Kinds whose filter always shows; the others show once the registry lists one. */
const ALWAYS_OFFERED: readonly CommunityKind[] = ["extension", "setup"];
export const COMMUNITY_SORTS: readonly CommunitySort[] = ["featured", "downloads", "updated", "stars", "name"];

/** Where the section sends a person when the registry has nothing to show yet. */
export const COMMUNITY_SITE = "https://cmux.com/extensions";

/** One release of a community item. */
export interface CommunityRelease {
  version: string;
  tag: string;
  commit: string;
  date?: string;
}

/** One row of `catalog.list {source: "community"}`. */
export interface CommunityRow {
  source: "community";
  /** `HOST/OWNER/REPO[/PATH]`. */
  ref: string;
  app?: string;
  kind: CommunityKind | string;
  name: string;
  tagline?: string;
  description: string;
  author: string;
  author_url?: string;
  repository: string;
  page_url?: string;
  icon_url?: string;
  categories: string[];
  downloads: number;
  stars: number;
  /** ISO 8601. */
  updated_at?: string;
  latest_release?: CommunityRelease;
  version?: string;
  min_cmux?: string;
  commit: string;
  /** What `apps.install {app}` takes: `ref@commit`, the reviewed commit. */
  install_app: string;
  installed: boolean;
}

/** `catalog.get {source: "community", ref}`. */
export interface CommunityDetail extends CommunityRow {
  /** Markdown at the reviewed commit. */
  readme: string;
  changelog?: string;
  screenshots: string[];
  license?: string;
  versions: CommunityRelease[];
}

/** An item installed on another of the person's devices, not on this one. */
export interface CommunityElsewhere {
  ref: string;
  kind: string;
  tag?: string;
  commit: string;
  app?: string;
  name?: string;
  install_app: string;
  action: "install_on_this_mac";
}

interface WireCommunityPage {
  source?: string;
  listings?: unknown[];
  next_cursor?: string | null;
  fetched_at?: number | null;
  stale?: boolean;
  refreshing?: boolean;
  error?: string | null;
  on_other_devices?: unknown[];
}

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
const count = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.floor(value) : 0;

function releaseFrom(value: unknown): CommunityRelease | undefined {
  const item = value as Record<string, unknown> | null;
  const version = text(item?.version);
  const tag = text(item?.tag);
  const commit = text(item?.commit);
  if (!version || !tag || !commit) return undefined;
  return { version, tag, commit, date: text(item?.date) };
}

/**
 * A community row, or undefined for anything else: an owner older than the Community source
 * ignores `source` and answers its own listings, which carry no `source: "community"`, `ref` or
 * `install_app`; the section never offers those.
 */
export function communityRow(value: unknown): CommunityRow | undefined {
  const item = value as Record<string, unknown> | null;
  if (!item || item.source !== "community") return undefined;
  const ref = text(item.ref);
  const name = text(item.name);
  const install = text(item.install_app);
  const commit = text(item.commit);
  if (!ref || !name || !install || !commit) return undefined;
  return {
    source: "community",
    ref,
    app: text(item.app),
    kind: text(item.kind) ?? "extension",
    name,
    tagline: text(item.tagline),
    description: text(item.description) ?? "",
    author: text(item.author) ?? "",
    author_url: text(item.author_url),
    repository: text(item.repository) ?? "",
    page_url: text(item.page_url),
    icon_url: text(item.icon_url),
    categories: Array.isArray(item.categories) ? item.categories.filter((c): c is string => typeof c === "string") : [],
    downloads: count(item.downloads),
    stars: count(item.stars),
    updated_at: text(item.updated_at),
    latest_release: releaseFrom(item.latest_release),
    version: text(item.version),
    min_cmux: text(item.min_cmux),
    commit,
    install_app: install,
    installed: item.installed === true,
  };
}

export function communityDetail(value: unknown): CommunityDetail | undefined {
  const row = communityRow(value);
  if (!row) return undefined;
  const item = value as Record<string, unknown>;
  return {
    ...row,
    readme: typeof item.readme === "string" ? item.readme : "",
    changelog: text(item.changelog),
    screenshots: Array.isArray(item.screenshots)
      ? item.screenshots.filter((s): s is string => typeof s === "string" && s !== "")
      : [],
    license: text(item.license),
    versions: Array.isArray(item.versions)
      ? item.versions.map(releaseFrom).filter((r): r is CommunityRelease => !!r)
      : [],
  };
}

export function elsewhereRow(value: unknown): CommunityElsewhere | undefined {
  const item = value as Record<string, unknown> | null;
  if (!item || item.action !== "install_on_this_mac") return undefined;
  const ref = text(item.ref);
  const install = text(item.install_app);
  const commit = text(item.commit);
  if (!ref || !install || !commit) return undefined;
  return {
    ref,
    kind: text(item.kind) ?? "extension",
    tag: text(item.tag),
    commit,
    app: text(item.app),
    name: text(item.name),
    install_app: install,
    action: "install_on_this_mac",
  };
}

/** The section's state: what it shows, before or after the owner answers. */
export type CommunityStatus = "idle" | "loading" | "ready";

export interface CommunitySnapshot {
  /** The Community tab is the one showing. */
  active: boolean;
  query: string;
  kind?: CommunityKind;
  /** The kind filters offered: Extensions and Setups, plus every other kind the registry listed. */
  kinds: CommunityKind[];
  sort: CommunitySort;
  status: CommunityStatus;
  rows: CommunityRow[];
  elsewhere: CommunityElsewhere[];
  /** The owner is fetching the registry; `apps-changed` follows. */
  refreshing: boolean;
  /**
   * The owner has nothing to offer yet: the registry is empty or unreachable, or the owner is
   * older than the Community source. The section shows its empty state, never the error.
   */
  unavailable: boolean;
  /** The ref whose page shows. */
  selection?: string;
  detail?: CommunityDetail;
  detailStatus: "idle" | "loading" | "ready" | "missing";
  /** `install_app` values whose install the person started and the host has not answered yet. */
  installing: string[];
}

/** Rows a page asks for at once; the owner's index is bounded (a few hundred items). */
const PAGE = 100;
const MAX_PAGES = 10;

export function parseCommunityRoute(hash: string): { active: boolean; ref?: string } {
  const raw = hash.replace(/^#/, "");
  const [path, search = ""] = raw.split("?");
  const active = path?.replace(/^\/+/, "").split("/")[0] === "community";
  const ref = active ? (new URLSearchParams(search).get("ref") ?? undefined) : undefined;
  return { active, ref: ref || undefined };
}

export class CommunityStore {
  private snapshot: CommunitySnapshot;
  private readonly listeners = new Set<() => void>();
  private unwatch?: () => void;
  private watching = false;
  private generation = 0;
  private detailGeneration = 0;
  /** A change arrived while the tab was hidden: the next visit re-reads. */
  private dirty = true;
  /** Every kind an unfiltered read listed, so a kind's filter stays while another one is on. */
  private readonly seenKinds = new Set<string>();

  constructor(
    private readonly client: Pick<PageClient, "call" | "subscribe"> | null,
    /** The page's install path (AppsStore.install): idempotent, through the host's consent card. */
    private readonly installApp: (app: string) => Promise<void>,
    hash = "",
  ) {
    const route = parseCommunityRoute(hash);
    this.snapshot = {
      active: route.active,
      query: "",
      kinds: [...ALWAYS_OFFERED],
      sort: "featured",
      status: "idle",
      rows: [],
      elsewhere: [],
      refreshing: false,
      unavailable: false,
      selection: route.ref,
      detailStatus: route.ref ? "loading" : "idle",
      installing: [],
    };
  }

  getSnapshot = (): CommunitySnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Listens for `apps-changed`; reads only once the tab shows (the registry is not fetched
   * for a person who never opens Community). */
  async start(): Promise<void> {
    if (!this.client || this.watching) return;
    this.watching = true;
    try {
      const unwatch = await this.client.subscribe<AppsChanged & { transaction?: string }>(AppsOps.watch, () =>
        this.changed(),
      );
      if (!this.watching) unwatch();
      else this.unwatch = unwatch;
    } catch {
      // An owner without the change stream still answers reads.
    }
    if (this.snapshot.active) await this.reload();
  }

  stop(): void {
    this.watching = false;
    ++this.generation;
    ++this.detailGeneration;
    this.unwatch?.();
    this.unwatch = undefined;
  }

  /** Any `apps-changed` (a registry refresh, an install anywhere) re-reads an open section. */
  private changed(): void {
    this.dirty = true;
    if (this.snapshot.active) void this.reload();
  }

  setActive(active: boolean): void {
    if (active === this.snapshot.active) return;
    this.set({ active });
    if (active && (this.dirty || this.snapshot.status === "idle")) void this.reload();
  }

  /** The host set a new fragment: `#/community[?ref=...]` shows the section (and a page). */
  applyRoute(hash: string): void {
    const route = parseCommunityRoute(hash);
    this.setActive(route.active);
    if (route.active && route.ref !== this.snapshot.selection) void this.select(route.ref);
  }

  setQuery(query: string): void {
    if (query === this.snapshot.query) return;
    this.set({ query });
    void this.reload();
  }

  /** A kind filter; the same kind again clears it. */
  setKind(kind: CommunityKind | undefined): void {
    const next = this.snapshot.kind === kind ? undefined : kind;
    this.set({ kind: next });
    void this.reload();
  }

  setSort(sort: CommunitySort): void {
    if (sort === this.snapshot.sort) return;
    this.set({ sort });
    void this.reload();
  }

  /** Re-reads the rows (every page) and the items on other devices. */
  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    this.dirty = false;
    if (this.snapshot.status === "idle") this.set({ status: "loading" });
    const { query, kind, sort } = this.snapshot;
    const rows: CommunityRow[] = [];
    let elsewhere: CommunityElsewhere[] = [];
    let refreshing = false;
    let error: string | undefined;
    let community = false;
    try {
      let cursor: string | null | undefined;
      for (let page = 0; page < MAX_PAGES; page += 1) {
        const params: Record<string, unknown> = { source: "community", sort, limit: PAGE };
        if (query.trim()) params.query = query.trim();
        if (kind) params.kind = kind;
        if (cursor) params.cursor = cursor;
        const answer = await this.client.call<WireCommunityPage>(AppsOps.catalogList, params);
        if (generation !== this.generation) return;
        community = community || answer?.source === "community";
        for (const value of answer?.listings ?? []) {
          const row = communityRow(value);
          if (row) rows.push(row);
        }
        if (page === 0) {
          elsewhere = (answer?.on_other_devices ?? [])
            .map(elsewhereRow)
            .filter((row): row is CommunityElsewhere => !!row);
          refreshing = answer?.refreshing === true;
          error = text(answer?.error);
        }
        cursor = answer?.next_cursor;
        if (!cursor) break;
      }
    } catch (failure) {
      if (generation !== this.generation) return;
      // An owner that refuses or does not know the Community source has nothing to offer: the
      // section's empty state, never an error wall. A lost link is the page's disconnected state.
      this.set({
        status: "ready",
        rows: [],
        elsewhere: [],
        refreshing: false,
        unavailable: true,
      });
      if (isPageError(failure) && failure.retryable) this.dirty = true;
      return;
    }
    if (!kind) for (const row of rows) this.seenKinds.add(row.kind);
    this.set({
      status: "ready",
      rows,
      kinds: COMMUNITY_KINDS.filter(
        (offered) => ALWAYS_OFFERED.includes(offered) || offered === kind || this.seenKinds.has(offered),
      ),
      elsewhere,
      refreshing,
      unavailable: !community || (rows.length === 0 && !!error),
    });
    if (this.snapshot.selection) await this.loadDetail(this.snapshot.selection);
  }

  /** Shows a row's page (its README), or the list again with undefined. */
  async select(ref: string | undefined): Promise<void> {
    ++this.detailGeneration;
    this.set({
      selection: ref,
      detail: ref && this.snapshot.detail?.ref === ref ? this.snapshot.detail : undefined,
      detailStatus: ref ? "loading" : "idle",
    });
    if (ref) await this.loadDetail(ref);
  }

  private async loadDetail(ref: string): Promise<void> {
    if (!this.client) return;
    const generation = ++this.detailGeneration;
    try {
      const detail = communityDetail(await this.client.call<unknown>(AppsOps.catalogGet, { source: "community", ref }));
      if (generation !== this.detailGeneration || this.snapshot.selection !== ref) return;
      this.set(detail ? { detail, detailStatus: "ready" } : { detail: undefined, detailStatus: "missing" });
    } catch {
      if (generation !== this.detailGeneration || this.snapshot.selection !== ref) return;
      this.set({ detail: undefined, detailStatus: "missing" });
    }
  }

  /**
   * Installs a row or an item from another device: `apps.install {app: install_app}` on the
   * page's install path, which the host confirms on its consent card. Then re-reads.
   */
  async install(installApp: string): Promise<void> {
    if (this.snapshot.installing.includes(installApp)) return;
    this.set({ installing: [...this.snapshot.installing, installApp] });
    try {
      await this.installApp(installApp);
    } finally {
      this.set({ installing: this.snapshot.installing.filter((app) => app !== installApp) });
    }
    await this.reload();
  }

  private set(patch: Partial<CommunitySnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

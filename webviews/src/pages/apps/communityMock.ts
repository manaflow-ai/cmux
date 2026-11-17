// l10n-allow-file: sample registry data (public-safe names, refs and READMEs), not shipped UI.
// A Community source for the gallery and tests: wraps a page client (the App Store's mock
// provider) and answers `catalog.list` / `catalog.get` with `source: "community"` the way the
// owner does (cmux-tui-core apps/community.rs). Everything else goes to the wrapped client.
// Installing a community item here answers `done` and fires `apps-changed`; in the app the host's
// consent card comes first.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import type { CommunityDetail, CommunityElsewhere, CommunityRow } from "./community";
import { AppsOps } from "./types";

export interface CommunityMockData {
  items: CommunityDetail[];
  elsewhere?: CommunityElsewhere[];
  /** The owner's `error`: the registry fetch failed (with or without a cache). */
  error?: string;
  refreshing?: boolean;
  /** The owner refuses the Community source (an older owner, a relay that drops it). */
  refuse?: boolean;
  /** An install waits on the consent card and never answers (the in-flight state). */
  holdInstall?: boolean;
}

export class CommunityMockProvider implements PageClient {
  readonly calls: { op: string; params: Record<string, unknown> }[] = [];
  private readonly watchers = new Set<(data: unknown, seq: number) => void>();
  private seq = 0;

  constructor(
    private readonly inner: PageClient,
    public data: CommunityMockData,
  ) {}

  async call<R>(op: string, rawParams: unknown): Promise<R> {
    const params = (rawParams ?? {}) as Record<string, unknown>;
    const { idempotency_key: _key, ...rest } = params;
    this.calls.push({ op, params: rest });
    const community = params.source === "community";
    if (community && this.data.refuse) throw pageError("cmux.protocol.bad_request", "unknown field source");
    if (op === AppsOps.catalogList && community) return this.list(params) as R;
    if (op === AppsOps.catalogGet && community) {
      const item = this.data.items.find((row) => row.ref === params.ref);
      if (!item) throw pageError("apps.community.unknown", "no such community item");
      return structuredClone(item) as R;
    }
    if (op === AppsOps.install && typeof params.app === "string") {
      const app = params.app;
      const row = this.data.items.find((item) => item.install_app === app);
      const elsewhere = this.data.elsewhere?.find((item) => item.install_app === app);
      if (row || elsewhere) {
        if (this.data.holdInstall) return new Promise<R>(() => {});
        if (row) row.installed = true;
        this.data.elsewhere = this.data.elsewhere?.filter((item) => item.install_app !== app);
        this.changed();
        return { status: "done" } as R;
      }
    }
    return this.inner.call<R>(op, rawParams);
  }

  private list(params: Record<string, unknown>) {
    const query = typeof params.query === "string" ? params.query.toLowerCase() : "";
    let rows: CommunityRow[] = this.data.items.filter(
      (row) =>
        (!params.kind || row.kind === params.kind) &&
        (!query ||
          [row.name, row.description, row.author, row.ref, row.tagline ?? "", ...row.categories].some((field) =>
            field.toLowerCase().includes(query),
          )),
    );
    const by =
      <T>(key: (row: CommunityRow) => T, desc = true) =>
      (a: CommunityRow, b: CommunityRow) => {
        const x = key(a);
        const y = key(b);
        return x === y ? 0 : x < y === desc ? 1 : -1;
      };
    if (params.sort === "downloads") rows = [...rows].sort(by((row) => row.downloads));
    if (params.sort === "stars") rows = [...rows].sort(by((row) => row.stars));
    if (params.sort === "updated") rows = [...rows].sort(by((row) => row.updated_at ?? ""));
    if (params.sort === "name") rows = [...rows].sort(by((row) => row.name.toLowerCase(), false));
    const listings = rows.map((item) => {
      const { readme: _r, changelog: _c, screenshots: _s, license: _l, versions: _v, ...row } = structuredClone(item);
      return row;
    });
    return {
      source: "community",
      listings,
      next_cursor: null,
      fetched_at: this.data.items.length ? Date.UTC(2026, 10, 16) : null,
      stale: false,
      refreshing: this.data.refreshing === true,
      ...(this.data.error ? { error: this.data.error } : {}),
      on_other_devices: structuredClone(this.data.elsewhere ?? []),
    };
  }

  /** `apps-changed {transaction: "community"}`, as the owner fires after a registry fetch. */
  changed(): void {
    this.seq += 1;
    for (const watcher of this.watchers) watcher({ revision: this.seq, transaction: "community" }, this.seq);
  }

  async subscribe<E>(
    stream: string,
    onEvent: (data: E, seq: number) => void,
    filter?: Record<string, unknown>,
  ): Promise<() => void> {
    const unsubscribe = await this.inner.subscribe(stream, onEvent, filter);
    if (stream !== AppsOps.watch) return unsubscribe;
    const watcher = onEvent as (data: unknown, seq: number) => void;
    this.watchers.add(watcher);
    return () => {
      this.watchers.delete(watcher);
      unsubscribe();
    };
  }

  handle(op: string, handler: PageHandler): () => void {
    return this.inner.handle(op, handler);
  }
}

const COMMIT = "4f1c2a9b8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b";

function item(
  ref: string,
  name: string,
  kind: "extension" | "setup" | "theme" | "snippet",
  fields: Partial<CommunityDetail> & Pick<CommunityDetail, "description" | "author">,
): CommunityDetail {
  return {
    source: "community",
    ref,
    kind,
    name,
    repository: `https://${ref}`,
    categories: [],
    downloads: 0,
    stars: 0,
    commit: COMMIT,
    install_app: `${ref}@${COMMIT}`,
    installed: false,
    readme: "",
    screenshots: [],
    versions: [],
    ...fields,
  };
}

/** A public-safe sample registry: two extensions, two setups, a theme and a snippet by sample authors. */
export function sampleCommunity(): CommunityMockData {
  return {
    items: [
      item("github.com/sample-author/focus-timer", "Focus Timer", "extension", {
        tagline: "A pomodoro timer in the sidebar that mutes notifications while you focus",
        description: "Start a 25 minute focus block from the sidebar or the command palette.",
        author: "sample-author",
        categories: ["productivity"],
        downloads: 12400,
        stars: 318,
        updated_at: "2026-11-12T09:30:00Z",
        version: "1.3.0",
        license: "MIT",
        latest_release: { version: "1.3.0", tag: "v1.3.0", commit: COMMIT, date: "2026-11-12" },
        readme: [
          "# Focus Timer",
          "",
          "A small timer that lives in the sidebar. Start a block, and cmux holds notifications until it ends.",
          "",
          "## Features",
          "",
          "- Start, pause and skip from the sidebar or the command palette",
          "- Notifications wait until the block ends",
          "- A short summary of the day's blocks",
          "",
          "## Settings",
          "",
          "| Setting | Default |",
          "| --- | --- |",
          "| `focusTimer.minutes` | `25` |",
          "| `focusTimer.breakMinutes` | `5` |",
          "",
          "Install it, then run **Focus Timer: Start** from the command palette.",
        ].join("\n"),
      }),
      item("github.com/sample-author/teal-twin", "Teal Twin", "theme", {
        tagline: "A calm teal theme for the terminal, the sidebar and the browser",
        description: "Matching light and dark teal colors for every surface.",
        author: "sample-author",
        categories: ["themes"],
        downloads: 8250,
        stars: 204,
        updated_at: "2026-10-28T15:00:00Z",
        version: "2.0.1",
        installed: true,
        readme: "# Teal Twin\n\nMatching light and dark teal colors for every surface.",
      }),
      item("github.com/example-org/standup-notes", "Standup Notes", "extension", {
        tagline: "Yesterday's commits and today's plan as a note, one click before standup",
        description: "Collects your commits since yesterday into a short note.",
        author: "example-org",
        categories: ["developer-tools"],
        downloads: 3120,
        stars: 77,
        updated_at: "2026-11-15T08:00:00Z",
        version: "0.9.2",
        readme: "# Standup Notes\n\nCollects your commits since yesterday into a short note.",
      }),
      item("github.com/example-org/git-log-graph", "Git Log Graph", "snippet", {
        tagline: "A one-key command that prints the branch graph of the current repository",
        description: "Adds a command that runs git log as a compact, colored branch graph.",
        author: "example-org",
        categories: ["developer-tools"],
        downloads: 2210,
        stars: 41,
        updated_at: "2026-11-09T10:15:00Z",
        readme: "# Git Log Graph\n\nAdds a command that runs git log as a compact, colored branch graph.",
      }),
      item("github.com/example-org/rust-workspace", "Rust Workspace", "setup", {
        tagline: "A three-pane layout with cargo watch, tests and a scratch terminal",
        description: "Opens an editor pane, a cargo watch pane and a test pane for a Rust project.",
        author: "example-org",
        categories: ["layouts"],
        downloads: 1980,
        stars: 52,
        updated_at: "2026-11-02T12:00:00Z",
        readme: "# Rust Workspace\n\nOpens an editor pane, a cargo watch pane and a test pane.",
      }),
      item("github.com/sample-author/writing-desk", "Writing Desk", "setup", {
        tagline: "A quiet layout for writing: one Markdown pane and a preview",
        description: "One Markdown pane with its preview beside it, and nothing else.",
        author: "sample-author",
        categories: ["layouts"],
        downloads: 640,
        stars: 19,
        updated_at: "2026-09-21T18:45:00Z",
        readme: "# Writing Desk\n\nOne Markdown pane with its preview beside it.",
      }),
    ],
    elsewhere: [
      {
        ref: "github.com/example-org/pr-radar",
        kind: "extension",
        tag: "v1.1.0",
        commit: COMMIT,
        name: "PR Radar",
        install_app: `github.com/example-org/pr-radar@${COMMIT}`,
        action: "install_on_this_mac",
      },
    ],
  };
}

// Where a followed link goes (plans/cmux-next/diff-host.md S6): `#anchor` scrolls to its heading in
// this file; a relative markdown file opens in this page (link history: the `back` and `forward`
// page commands); another relative file opens in the file viewer, http(s) in a cmux browser tab
// and mailto:/tel: in the system handler, all through `cmux.markdown.openLink`. A relative target
// that does not exist goes nowhere (its hover card says so).
import type { PageClient } from "../shared/pageClient";
import { MARKDOWN_OPEN_LINK_OP, MARKDOWN_RESOLVE_LINKS_OP } from "./host";
import { parseLink, type LinkResolver, type ResolvedLink } from "./links";
import type { HistoryEntry, MarkdownStore } from "./store";

export interface RouterDeps {
  store: Pick<MarkdownStore, "getState" | "navigate" | "go">;
  client: PageClient | null;
  resolver: Pick<LinkResolver, "get">;
  scrollToAnchor(anchor: string): boolean;
  scroll: { get(): number; set(top: number): void };
  /** Runs after the page shows another file (the editor has loaded it). */
  afterShow?(run: () => void): void;
}

export class LinkRouter {
  constructor(private readonly deps: RouterDeps) {}

  /** Follows `href` from the current file. */
  async follow(href: string): Promise<void> {
    const { store, client } = this.deps;
    const from = store.getState().config?.path;
    const link = parseLink(href);
    if (link.kind === "anchor") {
      this.deps.scrollToAnchor(link.anchor);
      return;
    }
    if (!from || !client || link.kind === "unsafe") return;
    if (link.kind === "external" || link.kind === "mail") {
      await client.call(MARKDOWN_OPEN_LINK_OP, { path: from, href, kind: link.kind }).catch(() => undefined);
      return;
    }
    const resolved = this.deps.resolver.get(link.path) ?? (await this.resolve(from, link.path));
    if (!resolved?.exists || !resolved.path) return;
    if (link.kind === "file" || resolved.kind !== "markdown") {
      await client
        .call(MARKDOWN_OPEN_LINK_OP, { path: from, href, kind: "file", target: resolved.path })
        .catch(() => undefined);
      return;
    }
    const entry = await store.navigate(resolved.path, link.anchor, this.deps.scroll.get());
    if (entry) this.land(entry, false);
  }

  /** The `back` (-1) and `forward` (+1) page commands. */
  async go(delta: -1 | 1): Promise<void> {
    const entry = await this.deps.store.go(delta, this.deps.scroll.get());
    if (entry) this.land(entry, true);
  }

  private land(entry: HistoryEntry, restore: boolean): void {
    const place = () => {
      if (restore) this.deps.scroll.set(entry.scroll);
      else if (!entry.anchor || !this.deps.scrollToAnchor(entry.anchor)) this.deps.scroll.set(0);
    };
    if (this.deps.afterShow) this.deps.afterShow(place);
    else place();
  }

  private async resolve(from: string, path: string): Promise<ResolvedLink | undefined> {
    try {
      const answer = await this.deps.client!.call<{ links?: Record<string, ResolvedLink> }>(MARKDOWN_RESOLVE_LINKS_OP, {
        from,
        paths: [path],
      });
      return answer?.links?.[path];
    } catch {
      return undefined;
    }
  }
}

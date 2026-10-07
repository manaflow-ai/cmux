// The page shell (plans/cmux-next/react-pages.md "Page shell"): one prewarmed document at
// `cmux-page://cmux.shell/` that mounts first-party pages without a navigation. The host claims it
// with `page.claim {page, route, context}` and clears it with `page.reset`; both are host calls on
// the shell's one bridge client. Each page gets a fresh root element and a scoped client; a reset
// ends everything the page opened and clears the document (documentReset.ts) before the next page.
import { createStrings, type StringTable, type Strings } from "../shared/i18n";
import { pageError, type PageClient } from "../shared/pageClient";
import {
  resetDocument,
  snapshotDocument,
  extendSnapshot,
  type DocumentSnapshot,
  type ShellWindow,
} from "./documentReset";
import { ScopedPageClient } from "./scopedClient";

/** What a shell page gets when it mounts. */
export interface ShellContext {
  /** The page's client: calls and streams in its namespace, ended by `page.reset`. */
  readonly client: PageClient;
  /** The page's strings from its own table, in the app's language. */
  strings(table: StringTable): Strings;
  /** The route the host asked for (`#/...`), or "". */
  readonly route: string;
  /** The host's context for this claim (the page defines its shape). */
  readonly context: unknown;
  /** Adds a stylesheet for this page; the reset removes it. */
  style(cssText: string): void;
}

/** A mounted shell page. `resume` takes the claim of a page mounted ahead of it (a prepared spare). */
export interface MountedShellPage {
  unmount(): void;
  resume?(context: unknown, route: string): void;
}

export interface ShellPageModule {
  mount(root: HTMLElement, ctx: ShellContext): MountedShellPage;
}

export interface ShellPage {
  readonly id: string;
  load(): Promise<ShellPageModule>;
}

export const ShellOps = {
  claim: "page.claim",
  reset: "page.reset",
  resume: "page.resume",
} as const;

interface Mounted {
  readonly page: string;
  readonly client: ScopedPageClient;
  readonly view: MountedShellPage;
  /** Mounted ahead of its claim (`prepare`), waiting for `page.resume`. */
  prepared: boolean;
}

export interface ShellOptions {
  readonly client: PageClient;
  readonly root: HTMLElement;
  readonly pages: readonly ShellPage[];
  readonly win: ShellWindow;
  readonly languages?: () => readonly string[];
  /** Called once the claimed page drew its first frame (the host's paint probe). */
  readonly painted?: () => void;
}

export class PageShell {
  private readonly snapshot: DocumentSnapshot;
  private readonly modules = new Map<string, ShellPageModule>();
  private readonly loads = new Map<string, Promise<ShellPageModule>>();
  private mounted: Mounted | null = null;
  /** The last shell events (claim, mount, reset), for the host's debug state and its tests. */
  readonly events: string[] = [];
  private cleanup: Promise<void> | null = null;
  /** A prepare claim still waiting for its chunk or the last reset: a resume waits for it. */
  private preparing: { page: string; done: Promise<unknown> } | null = null;
  private claims = 0;

  constructor(private readonly options: ShellOptions) {
    this.snapshot = snapshotDocument(options.win);
    options.client.handle(ShellOps.claim, (params) => this.claim(params));
    options.client.handle(ShellOps.reset, () => this.reset());
    options.client.handle(ShellOps.resume, (params) => this.resume(params));
  }

  /** Keeps the globals defined so far across resets (the boot code's own, after construction). */
  keepCurrentGlobals(): void {
    if (!this.mounted) extendSnapshot(this.options.win, this.snapshot);
  }

  /** The mounted page id, or null. */
  get current(): string | null {
    return this.mounted?.page ?? null;
  }

  /** Loads every registered page's chunk (after the shell's first idle moment). */
  preload(): Promise<void> {
    return Promise.all(this.options.pages.map((page) => this.load(page).catch(() => undefined))).then(() => undefined);
  }

  private load(page: ShellPage): Promise<ShellPageModule> {
    const known = this.loads.get(page.id);
    if (known) return known;
    const loading = page.load().then((module) => {
      this.modules.set(page.id, module);
      // A page module's own top-level globals are code, not page state: keep them across resets.
      // Only while no page is mounted, so nothing a mounted page did is kept.
      if (!this.mounted) extendSnapshot(this.options.win, this.snapshot);
      return module;
    });
    this.loads.set(page.id, loading);
    loading.catch(() => this.loads.delete(page.id));
    return loading;
  }

  /** `page.claim`: mounts the page (synchronously when its chunk is loaded); a mounted page is reset first. */
  private note(event: string): void {
    this.events.push(event);
    if (this.events.length > 50) this.events.shift();
  }

  claim(params: unknown): Promise<{ page: string; prepared?: true }> | { page: string; prepared?: true } {
    this.note(`claim ${String((params as { page?: unknown } | null)?.page)}`);
    const {
      page: id,
      route,
      context,
      prepare,
    } = (params ?? {}) as {
      page?: unknown;
      route?: unknown;
      context?: unknown;
      prepare?: unknown;
    };
    const page = this.options.pages.find((entry) => entry.id === id);
    if (typeof id !== "string" || !page) throw pageError("cmux.shell.unknown_page", String(id));
    if (this.mounted) void this.reset();
    const claim = ++this.claims;
    const mount = (module: ShellPageModule) => {
      if (claim !== this.claims) throw pageError("cmux.protocol.closed", "superseded", true);
      this.mount(
        id,
        module,
        typeof route === "string" ? route : "",
        prepare === true ? null : context,
        prepare === true,
      );
      return prepare === true ? { page: id, prepared: true as const } : { page: id };
    };
    const module = this.modules.get(id);
    this.preparing = null;
    if (module && !this.cleanup) return mount(module);
    this.note(module ? "claim waits for the last reset" : "claim waits for the page chunk");
    const later = Promise.all([this.load(page), this.cleanup]).then(([loaded]) => mount(loaded));
    if (prepare === true) {
      const preparing = { page: id, done: later.catch(() => undefined) };
      this.preparing = preparing;
      void preparing.done.then(() => {
        if (this.preparing === preparing) this.preparing = null;
      });
    }
    return later;
  }

  /**
   * `page.resume`: hands the claim's session to the page mounted ahead of its claim (after its
   * prepare claim, when that one still waits for its chunk or the last reset).
   */
  resume(params: unknown): { page: string } | Promise<{ page: string }> {
    const id = (params as { page?: unknown } | null)?.page;
    const preparing = this.preparing;
    if (preparing && preparing.page === id && this.mounted?.page !== id) {
      return preparing.done.then(() => this.resumeNow(params));
    }
    return this.resumeNow(params);
  }

  private resumeNow(params: unknown): { page: string } {
    const { page: id, route, context } = (params ?? {}) as { page?: unknown; route?: unknown; context?: unknown };
    const mounted = this.mounted;
    if (!mounted || !mounted.prepared || mounted.page !== id) {
      throw pageError("cmux.shell.not_prepared", `${String(id)} is not the prepared page`);
    }
    mounted.prepared = false;
    if (mounted.view.resume) mounted.view.resume(context, typeof route === "string" ? route : "");
    this.note(`resumed ${id}`);
    this.options.painted?.();
    return { page: id };
  }

  private mount(id: string, module: ShellPageModule, route: string, context: unknown, prepared = false): void {
    const { win } = this.options;
    const client = new ScopedPageClient(this.options.client);
    const element = win.document.createElement("div");
    element.className = "shell-page";
    element.dataset.shellPage = id;
    this.options.root.append(element);
    const languages = this.options.languages;
    const ctx: ShellContext = {
      client,
      route,
      context,
      strings: (table) => (languages ? createStrings(table, languages()) : createStrings(table)),
      style: (cssText) => {
        const style = win.document.createElement("style");
        style.dataset.shellPage = id;
        style.textContent = cssText;
        win.document.head.append(style);
      },
    };
    win.document.documentElement.dataset.cmuxPage = id;
    let page: MountedShellPage;
    try {
      page = module.mount(element, ctx);
    } catch (error) {
      client.close();
      void this.clear();
      throw error;
    }
    this.mounted = { page: id, client, view: page, prepared };
    this.note(`mounted ${id}`);
    if (!prepared) this.options.painted?.();
  }

  /** `page.reset`: unmounts the page, ends its calls and streams, clears the document. */
  reset(): Promise<{ reset: true }> {
    this.note("reset");
    this.preparing = null;
    const mounted = this.mounted;
    this.mounted = null;
    this.claims++;
    if (mounted) {
      mounted.client.close();
      try {
        mounted.view.unmount();
      } catch {
        // A page that fails to unmount still loses its root below.
      }
    }
    return this.clear().then(() => ({ reset: true as const }));
  }

  private clear(): Promise<void> {
    const { win, root } = this.options;
    win.document.documentElement.dataset.cmuxPage = "shell";
    const cleanup = resetDocument(win, this.snapshot, root).finally(() => {
      if (this.cleanup === cleanup) this.cleanup = null;
    });
    this.cleanup = cleanup;
    return cleanup;
  }
}

// l10n-allow-file: fixture file names, not shipped UI.
// An in-memory `cmux.files.*` provider for the browser dev loop (`/files/?mock`) and the gallery.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { FilesOps, type FileEntry, type Listing, type RootInfo, type SearchResults } from "./types";

/** A folder tree: a folder is an object of its children, a file is `null`. */
export type MockTree = { [name: string]: MockTree | null };

export const sampleTree: MockTree = {
  ".github": { workflows: { "ci.yml": null } },
  docs: { "architecture.md": null, "setup.md": null },
  src: {
    components: { "Button.tsx": null, "Tree.tsx": null },
    "main.ts": null,
    "store.ts": null,
  },
  ".gitignore": null,
  "package.json": null,
  "README.md": null,
  "tsconfig.json": null,
};

/// The dev loop's tree: the sample plus what git ignores there (greyed out in the page).
export const devTree: MockTree = { ...sampleTree, ".env": null, node_modules: { react: { "index.js": null } } };

export class MockFilesProvider implements PageClient {
  readonly opened: string[] = [];
  /** Folders whose listing says more children were left out. */
  readonly truncated = new Set<string>();
  /** When set, `open` fails with this message. */
  openFailure?: string;
  /** Top-level names git ignores (listed greyed out, never found by search). */
  readonly ignored = new Set(["node_modules", ".env"]);

  constructor(
    private readonly tree: MockTree = sampleTree,
    private readonly root: RootInfo = { folder: "/Users/you/code/app", name: "app" },
    private readonly failure?: { code: string; message: string },
  ) {}

  async call<R>(op: string, params: unknown): Promise<R> {
    if (this.failure) throw pageError(this.failure.code, this.failure.message);
    const path = String((params as { path?: unknown } | undefined)?.path ?? "");
    switch (op) {
      case FilesOps.root:
        return this.root as R;
      case FilesOps.list:
        return this.list(path) as R;
      case FilesOps.search:
        return this.search(String((params as { query?: unknown } | undefined)?.query ?? "")) as R;
      case FilesOps.open:
        if (this.openFailure) throw pageError("cmux.files.open_failed", this.openFailure);
        this.opened.push(path);
        return undefined as R;
    }
    throw pageError("cmux.op.unknown", op);
  }

  async subscribe(): Promise<() => void> {
    return () => {};
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }

  /** Every file path whose name holds the query's letters in order, as the session host ranks loosely. */
  private search(query: string): SearchResults {
    const needle = query.toLowerCase();
    const paths: string[] = [];
    const walk = (node: MockTree, prefix: string) => {
      for (const [name, child] of Object.entries(node)) {
        const path = prefix ? `${prefix}/${name}` : name;
        if (child) walk(child, path);
        else if (this.ignored.has(path.split("/")[0]!)) continue;
        else if (path.toLowerCase().includes(needle)) paths.push(path);
      }
    };
    walk(this.tree, "");
    return { results: paths.map((path) => ({ path })) };
  }

  private list(path: string): Listing {
    let node: MockTree | null | undefined = this.tree;
    for (const part of path ? path.split("/") : []) node = node?.[part];
    if (!node) throw pageError("cmux.files.not_found", path);
    const entries: FileEntry[] = Object.entries(node).map(([name, child]) => ({
      name,
      kind: child ? "directory" : "file",
      ...(this.ignored.has(path ? `${path}/${name}` : name) ? { ignored: true } : {}),
    }));
    entries.sort(
      (a, b) =>
        Number(b.kind === "directory") - Number(a.kind === "directory") ||
        a.name.toLowerCase().localeCompare(b.name.toLowerCase()),
    );
    return { entries, truncated: this.truncated.has(path) };
  }
}

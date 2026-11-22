// An in-memory `cmux.artifacts.*` provider for the browser dev loop (`/artifacts/?mock`) and the
// gallery: a small synced tree with an HTML artifact, a memory note with two revisions and JSON,
// shaped like cmux-platform's `/v1/artifacts` answers (tree lists immediate children only).
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { ArtifactsOps, type ArtifactCommit, type ArtifactFile, type ArtifactsTree } from "./types";

/** `synced` has files; `empty` has nothing saved yet (the platform answers 404 at the root). */
export type MockArtifactsKind = "synced" | "empty";

const HEAD = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678";
const PREVIOUS = "99887766554433221100ffeeddccbbaa99887766";

const html = `<!doctype html><meta charset="utf-8"><style>body{font-family:system-ui;padding:28px;color:#17202a}td{padding:4px 12px 4px 0}</style><h1>Release dashboard</h1><p>Nightly builds for the last three days.</p><table><tr><td>Oct 27</td><td>passed</td></tr><tr><td>Oct 28</td><td>passed</td></tr><tr><td>Oct 29</td><td>passed</td></tr></table><script>document.body.append("scripts never run in the preview")</script>`;
const note = `# Artifacts pane\n\nThe pane reads the synced tree, previews a file and shows its history.\n\n- HTML previews run no script\n- History compares a revision with its parent\n`;
const previousNote = `# Artifacts pane\n\nThe pane reads the synced tree, previews a file and shows its history.\n\n- HTML previews run no script\n`;
const data = `{\n  "build": "2026.10.29",\n  "passed": true\n}\n`;

const FILES: Record<string, { head: string; previous?: string; type: string }> = {
  "artifacts/release-dashboard/index.html": { head: html, type: "text/html" },
  "artifacts/release-dashboard/data.json": { head: data, type: "application/json" },
  "memory/claude/artifacts-pane.md": { head: note, previous: previousNote, type: "text/markdown" },
  "notes/launch.md": { head: "# Launch\n\nShip the Labs pane first.\n", type: "text/markdown" },
};

const COMMITS: ArtifactCommit[] = [
  {
    sha: HEAD,
    parents: [PREVIOUS],
    message: "Note how history compares revisions",
    authorName: "cmux",
    time: Date.UTC(2026, 9, 29, 16, 10),
    trailers: { session: "artifacts-pane", machine: "build-mini", harness: "claude" },
  },
  {
    sha: PREVIOUS,
    parents: [],
    message: "Save the artifacts pane notes",
    authorName: "cmux",
    time: Date.UTC(2026, 9, 28, 21, 32),
    trailers: { session: "artifacts-plan", machine: "laptop", harness: "codex" },
  },
];

export class MockArtifactsProvider implements PageClient {
  constructor(private readonly kind: MockArtifactsKind = "synced") {}

  async call<R>(op: string, params: unknown): Promise<R> {
    const { path = "", ref = "main" } = (params ?? {}) as { path?: string; ref?: string };
    if (this.kind === "empty") throw pageError("cmux.artifacts.not_found", "Nothing has been saved here yet.");
    if (op === ArtifactsOps.tree) return children(path) as R;
    if (op === ArtifactsOps.file) {
      const file = FILES[path];
      if (!file) throw pageError("cmux.artifacts.not_found", "Nothing has been saved here yet.");
      const old = ref === PREVIOUS;
      const content = old ? (file.previous ?? file.head) : file.head;
      return {
        path,
        size: content.length,
        contentType: file.type,
        commit: old ? PREVIOUS : HEAD,
        content,
      } as ArtifactFile as R;
    }
    if (op === ArtifactsOps.history) {
      const commits = FILES[path]?.previous ? COMMITS : COMMITS.slice(0, 1);
      return { commits: commits.map((commit) => ({ ...commit, paths: [path] })) } as R;
    }
    throw pageError("cmux.protocol.unknown_op", op);
  }

  async subscribe(): Promise<() => void> {
    return () => {};
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}

function children(path: string): ArtifactsTree {
  const prefix = path ? `${path}/` : "";
  const entries = new Map<string, ArtifactsTree["entries"][number]>();
  for (const [file, { head }] of Object.entries(FILES)) {
    if (!file.startsWith(prefix)) continue;
    const [name, ...rest] = file.slice(prefix.length).split("/");
    const blob = rest.length === 0;
    entries.set(name, {
      name,
      path: prefix + name,
      type: blob ? "blob" : "tree",
      ...(blob ? { size: head.length } : {}),
    });
  }
  return { ref: "main", sha: HEAD, entries: [...entries.values()] };
}

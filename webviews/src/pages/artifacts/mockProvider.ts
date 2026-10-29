import type { PageClient, PageHandler } from "../../shared/pageClient";
import type { ArtifactFile, ArtifactHistory, ArtifactsTree } from "./types";
import { ArtifactsOps } from "./types";

const html = `<!doctype html><meta charset="utf-8"><style>body{font:15px system-ui;padding:28px;color:#17202a}h1{font-size:24px}button{padding:8px 12px;border-radius:8px;border:1px solid #ccd}</style><h1>Release dashboard</h1><p>A versioned artifact rendered in an isolated frame.</p><button>Preview only</button>`;
const markdown = `# Build notes\n\nThe nightly artifact is ready for review.\n\n- Fast path enabled\n- No credentials in the bundle\n`;
const previousMarkdown = `# Build notes\n\nThe nightly artifact is ready for review.\n\n- Fast path enabled\n`;

export class MockArtifactsProvider implements PageClient {
  async call<R>(op: string, params: unknown): Promise<R> {
    const path = String((params as { path?: unknown } | undefined)?.path ?? "");
    if (op === ArtifactsOps.tree) {
      return { ref: "main", sha: "a1b2c3d", entries: [
        { name: "artifacts", path: "artifacts", type: "tree" },
        { name: "release-dashboard", path: "artifacts/release-dashboard", type: "tree" },
        { name: "index.html", path: "artifacts/release-dashboard/index.html", type: "blob", size: html.length },
        { name: "data.json", path: "artifacts/release-dashboard/data.json", type: "blob", size: 94 },
        { name: "memory", path: "memory", type: "tree" },
        { name: "codex", path: "memory/codex", type: "tree" },
        { name: "artifacts-pane.md", path: "memory/codex/artifacts-pane.md", type: "blob", size: markdown.length },
        { name: "notes", path: "notes", type: "tree" },
        { name: "launch.md", path: "notes/launch.md", type: "blob", size: 320 },
      ] } as R;
    }
    if (op === ArtifactsOps.file) {
      const ref = String((params as { ref?: unknown } | undefined)?.ref ?? "main");
      const content = path.endsWith("index.html") ? html : path.endsWith("data.json") ? '{"build":"2026.10.29","passed":true}' : ref === "9988776" ? previousMarkdown : markdown;
      return { path, content, contentType: path.endsWith(".html") ? "text/html" : "text/plain", commit: ref === "9988776" ? "9988776" : "a1b2c3d" } as R;
    }
    if (op === ArtifactsOps.history) {
      return { commits: [
        { sha: "a1b2c3d", parents: ["9988776"], message: "Update release dashboard", authorName: "Avery", time: "2026-10-29T04:10:00Z", trailers: { session: "session-42", machine: "build-mini", harness: "codex" }, paths: [path] },
        { sha: "9988776", parents: [], message: "Create release dashboard", authorName: "Avery", time: "2026-10-28T21:32:00Z", trailers: { session: "session-41", machine: "air-2", harness: "claude" }, paths: [path] },
      ] } as R;
    }
    throw new Error(`Unknown artifacts operation: ${op}`);
  }
  async subscribe(): Promise<() => void> { return () => {}; }
  handle(_op: string, _handler: PageHandler): () => void { return () => {}; }
}

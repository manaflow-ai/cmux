import {
  pageError,
  type PageClient,
  type PageHandler,
} from "../shared/pageClient";
import {
  SkillsOps,
  type DirectoryEntry,
  type DirectoryResult,
  type Harness,
} from "./types";

export const sampleEntries: DirectoryEntry[] = [
  {
    id: "terminal-workflows",
    kind: "skill",
    name: "Terminal workflows",
    description:
      "Reusable shell workflows for fast, repeatable agent sessions.",
    publisher: "cmux community",
    version: "1.0.0",
    targets: ["claude", "codex", "pi", "opencode"],
    installed: { claude: true },
  },
  {
    id: "git-review",
    kind: "skill",
    name: "Git review",
    description: "A compact review checklist for safe, focused changes.",
    publisher: "cmux community",
    version: "1.0.0",
    targets: ["claude", "codex", "pi", "opencode"],
    installed: {},
  },
  {
    id: "ui-polish",
    kind: "skill",
    name: "UI polish",
    description: "Practical guidance for stable, accessible interface changes.",
    publisher: "cmux community",
    version: "1.0.0",
    targets: ["claude", "codex", "pi", "opencode"],
    installed: {},
  },
  {
    id: "filesystem-tools",
    kind: "mcp",
    name: "Filesystem tools",
    description: "A local MCP server for bounded file inspection and edits.",
    publisher: "cmux community",
    version: "1.0.0",
    targets: ["claude", "codex", "pi", "opencode"],
    installed: { codex: true, opencode: true },
  },
  {
    id: "browser-tools",
    kind: "mcp",
    name: "Browser tools",
    description: "A local MCP server for browser inspection and automation.",
    publisher: "cmux community",
    version: "1.0.0",
    targets: ["claude", "codex", "pi", "opencode"],
    installed: {},
  },
  {
    id: "memory-tools",
    kind: "mcp",
    name: "Memory tools",
    description: "A small local MCP server for durable project notes.",
    publisher: "cmux community",
    version: "1.0.0",
    targets: ["claude", "codex", "pi", "opencode"],
    installed: {},
  },
  {
    id: "review-kit",
    kind: "plugin",
    name: "Review kit",
    description: "A plugin bundle with review prompts and change summaries.",
    publisher: "cmux community",
    version: "1.0.0",
    targets: ["claude", "codex", "pi", "opencode"],
    installed: {},
  },
  {
    id: "release-kit",
    kind: "plugin",
    name: "Release kit",
    description: "A plugin bundle for release notes and verification receipts.",
    publisher: "cmux community",
    version: "1.0.0",
    targets: ["claude", "codex", "pi", "opencode"],
    installed: {},
  },
];

export class MockSkillsProvider implements PageClient {
  private entries = structuredClone(sampleEntries);
  private readonly handlers = new Map<string, PageHandler>();
  private readonly subscriptions = new Map<
    number,
    (data: unknown, seq: number) => void
  >();
  private next = 1;

  async call<R>(op: string, params: unknown): Promise<R> {
    const input = params as {
      id?: string;
      query?: string;
      kind?: string;
      targets?: Harness[];
    };
    if (op === SkillsOps.list) {
      const query = input.query?.toLowerCase() ?? "";
      const entries = this.entries.filter(
        (entry) =>
          (!input.kind || entry.kind === input.kind) &&
          (!query ||
            `${entry.name} ${entry.description}`.toLowerCase().includes(query)),
      );
      return { schemaVersion: 1, entries } as R;
    }
    if (op === SkillsOps.install || op === SkillsOps.remove) {
      const entry = this.entries.find((candidate) => candidate.id === input.id);
      if (!entry) throw pageError("skills.directory.not_found", input.id ?? "");
      for (const harness of input.targets ?? entry.targets)
        entry.installed[harness] = op === SkillsOps.install;
      this.emit(entry.id);
      return { id: entry.id, installed: entry.installed } as R;
    }
    if (op === SkillsOps.status) {
      const entry = this.entries.find((candidate) => candidate.id === input.id);
      if (!entry) throw pageError("skills.directory.not_found", input.id ?? "");
      return { id: entry.id, installed: entry.installed } as R;
    }
    throw pageError("cmux.protocol.unknown_op", op);
  }

  async subscribe<E>(
    stream: string,
    onEvent: (data: E, seq: number) => void,
  ): Promise<() => void> {
    if (stream !== "cmux.skills.directory.changed")
      throw pageError("cmux.protocol.unknown_op", stream);
    const id = this.next++;
    this.subscriptions.set(id, onEvent as (data: unknown, seq: number) => void);
    return () => this.subscriptions.delete(id);
  }

  handle(op: string, handler: PageHandler): () => void {
    this.handlers.set(op, handler);
    return () => this.handlers.delete(op);
  }
  private emit(id: string): void {
    for (const listener of this.subscriptions.values())
      listener({ id }, this.next++);
  }
}

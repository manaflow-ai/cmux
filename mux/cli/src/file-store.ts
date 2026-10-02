import { appendFileSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { key, type MemoryStore, type Range } from "@mux/brain";

/**
 * mux memory as files: LOG.txt (one entry per line, append only) and
 * TREE/<lo>-<hi>.txt (summaries, rebuildable). The directory is a git repo;
 * `commit` records changes (the hooks call it, never per line).
 */
export class FileMemoryStore implements MemoryStore {
  readonly dir: string;
  private readonly log: string;
  private readonly tree: string;

  constructor(dir: string) {
    this.dir = dir;
    this.log = join(dir, "LOG.txt");
    this.tree = join(dir, "TREE");
    Bun.spawnSync(["mkdir", "-p", this.tree]);
    if (!existsSync(join(dir, ".git"))) {
      Bun.spawnSync(["git", "init", "-q"], { cwd: dir });
      Bun.spawnSync(["git", "config", "user.email", "mux@cmux.dev"], { cwd: dir });
      Bun.spawnSync(["git", "config", "user.name", "mux"], { cwd: dir });
    }
    if (!existsSync(this.log)) writeFileSync(this.log, "");
  }

  private lines(): string[] {
    const text = readFileSync(this.log, "utf8");
    return text ? text.split("\n").slice(0, -1) : [];
  }

  async length() {
    return this.lines().length;
  }

  async append(lines: string[]) {
    if (lines.length > 0) appendFileSync(this.log, `${lines.join("\n")}\n`);
    return this.lines().length;
  }

  async read(start: number, end: number) {
    return this.lines().slice(start, end);
  }

  async recall(pattern: string, limit: number) {
    const re = new RegExp(pattern, "i");
    const lines = this.lines();
    const hits: { index: number; line: string }[] = [];
    for (let i = lines.length - 1; i >= 0 && hits.length < limit; i--) {
      if (re.test(lines[i])) hits.push({ index: i, line: lines[i] });
    }
    return hits;
  }

  async getNodes(ranges: Range[]) {
    const found = new Map<string, string>();
    for (const r of ranges) {
      const file = join(this.tree, `${key(r)}.txt`);
      if (existsSync(file)) found.set(key(r), readFileSync(file, "utf8").trim());
    }
    return found;
  }

  async putNode(range: Range, summary: string) {
    writeFileSync(join(this.tree, `${key(range)}.txt`), `${summary}\n`);
  }

  async deleteNode(range: Range) {
    rmSync(join(this.tree, `${key(range)}.txt`), { force: true });
  }

  /** Commits LOG.txt and TREE/ when they changed. */
  commit(message: string): void {
    Bun.spawnSync(["git", "add", "-A"], { cwd: this.dir });
    Bun.spawnSync(["git", "commit", "-qm", message], {
      cwd: this.dir,
      stdout: "ignore",
      stderr: "ignore",
    });
  }
}

import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { key, type MemoryStore, type Range } from "./memory.ts";

/**
 * mux memory as files in a git repo: LOG.txt (one entry per line, append
 * only, the truth) and TREE/<lo>-<hi>.txt (summaries, rebuildable). Writers
 * call `commit` after a batch of writes (a hook, a note, a compaction step),
 * never per line. The brain host's hooks are the only writers of this repo.
 */
export class FileMemoryStore implements MemoryStore {
  readonly dir: string;
  private readonly log: string;
  private readonly tree: string;

  constructor(dir: string) {
    this.dir = dir;
    this.log = join(dir, "LOG.txt");
    this.tree = join(dir, "TREE");
    mkdirSync(this.tree, { recursive: true });
    if (!existsSync(join(dir, ".git"))) {
      git(dir, ["init", "-q"]);
      git(dir, ["config", "user.email", "mux@cmux.dev"]);
      git(dir, ["config", "user.name", "mux"]);
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
    const clean = lines.map((line) => line.replace(/\n/g, " "));
    if (clean.length > 0) appendFileSync(this.log, `${clean.join("\n")}\n`);
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

  /** Commits LOG.txt and TREE/ when they changed; returns whether a commit was made. */
  commit(message: string): boolean {
    git(this.dir, ["add", "-A"]);
    return git(this.dir, ["commit", "-qm", message]) === 0;
  }
}

function git(cwd: string, args: string[]): number {
  return Bun.spawnSync(["git", ...args], { cwd, stdout: "ignore", stderr: "ignore" }).exitCode;
}

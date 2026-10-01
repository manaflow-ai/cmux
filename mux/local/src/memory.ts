import { mkdirSync, appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { toLines } from "@mux/brain";

/**
 * The local mux's memory: an append-only LOG.txt in a git repo (one commit per
 * append). The agent reads the recent tail in its prompt and greps the rest
 * itself. Compaction (the summary tree) is not wired here yet.
 */
export class LocalMemory {
  readonly dir: string;
  readonly log: string;

  constructor(dir: string) {
    this.dir = dir;
    this.log = join(dir, "LOG.txt");
    mkdirSync(dir, { recursive: true });
    if (!existsSync(join(dir, ".git"))) {
      Bun.spawnSync(["git", "init", "-q"], { cwd: dir });
      Bun.spawnSync(["git", "config", "user.email", "mux@cmux.dev"], { cwd: dir });
      Bun.spawnSync(["git", "config", "user.name", "mux"], { cwd: dir });
    }
    if (!existsSync(this.log)) appendFileSync(this.log, "");
  }

  /** Appends one entry (split into log lines) and commits it. */
  async append(text: string): Promise<void> {
    const lines = toLines(`${new Date().toISOString().slice(0, 16)} ${text}`);
    if (lines.length === 0) return;
    appendFileSync(this.log, `${lines.join("\n")}\n`);
    const add = Bun.spawn(["git", "add", "LOG.txt"], { cwd: this.dir });
    await add.exited;
    const commit = Bun.spawn(["git", "commit", "-qm", `append ${lines.length}`], {
      cwd: this.dir,
      stdout: "ignore",
      stderr: "ignore",
    });
    await commit.exited;
  }

  /** The last `count` lines, numbered from the start of the log. */
  tail(count = 96): string {
    const lines = readFileSync(this.log, "utf8").split("\n").slice(0, -1);
    const start = Math.max(0, lines.length - count);
    return lines
      .slice(start)
      .map((line, i) => `#${start + i} ${line}`)
      .join("\n");
  }
}

import { key, type MemoryStore, type Range } from "@mux/brain";
import { exec } from "./freestyle.ts";

/**
 * A mux's memory as a git repo on a VM: LOG.txt (one line per entry, append
 * only) and TREE/<lo>-<hi>.txt (rebuildable summaries). Every write commits.
 * Commands go through Freestyle exec and use only BusyBox tools (the
 * `mux-memory-base` snapshot is BusyBox plus git); data travels on stdin or in
 * env, never in the command line. Recall patterns are POSIX extended regexes.
 */
export class GitExecMemoryStore implements MemoryStore {
  private readonly dir: string;
  private ready?: Promise<void>;
  private readonly apiKey: string;
  private readonly vmId: string;

  constructor(apiKey: string, vmId: string, muxId: string, baseDir = "/data/mux-memory") {
    this.apiKey = apiKey;
    this.vmId = vmId;
    if (!/^[A-Za-z0-9_-]+$/.test(muxId)) throw new Error(`bad mux id ${muxId}`);
    this.dir = `${baseDir}/${muxId}`;
  }

  private run(script: string, options: { stdin?: string; env?: Record<string, string> } = {}) {
    this.ready ??= exec(
      this.apiKey,
      this.vmId,
      `set -e; mkdir -p "${this.dir}/TREE"; cd "${this.dir}"; if [ ! -d .git ]; then git init -q; git config user.email mux@cmux.dev; git config user.name mux; touch LOG.txt; git add -A; git commit -qm init; fi`,
    ).then(() => undefined);
    return this.ready.then(() =>
      exec(this.apiKey, this.vmId, `set -e; cd "${this.dir}"; ${script}`, options),
    );
  }

  async length() {
    return Number((await this.run("wc -l < LOG.txt")).trim());
  }

  async append(lines: string[]) {
    if (lines.length === 0) return this.length();
    const out = await this.run(
      `cat >> LOG.txt; git add LOG.txt; git commit -qm "append ${lines.length}"; wc -l < LOG.txt`,
      {
        stdin: `${lines.join("\n")}\n`,
      },
    );
    return Number(out.trim());
  }

  async read(start: number, end: number) {
    if (end <= start) return [];
    const out = await this.run(`sed -n '${Math.floor(start) + 1},${Math.floor(end)}p' LOG.txt`);
    return out.split("\n").slice(0, end - start);
  }

  async recall(pattern: string, limit: number) {
    const out = await this.run(`grep -n -i -E -e "$P" LOG.txt | tail -n "$N" || true`, {
      env: { P: pattern, N: String(Math.max(1, Math.floor(limit))) },
    });
    return out
      .split("\n")
      .filter(Boolean)
      .map((row) => {
        const colon = row.indexOf(":");
        return { index: Number(row.slice(0, colon)) - 1, line: row.slice(colon + 1) };
      })
      .reverse();
  }

  async getNodes(ranges: Range[]) {
    const found = new Map<string, string>();
    if (ranges.length === 0) return found;
    // Keys are "<lo>-<hi>" with digits only, safe to split on spaces.
    const out = await this.run(
      `for k in $K; do f="TREE/$k.txt"; if [ -f "$f" ]; then printf '%s\\t' "$k"; cat "$f"; fi; done`,
      { env: { K: ranges.map(key).join(" ") } },
    );
    for (const row of out.split("\n")) {
      const tab = row.indexOf("\t");
      if (tab > 0) found.set(row.slice(0, tab), row.slice(tab + 1));
    }
    return found;
  }

  async putNode(range: Range, summary: string) {
    const name = `TREE/${key(range)}.txt`;
    await this.run(`cat > ${name}; git add ${name}; git commit -qm "summary ${key(range)}"`, {
      stdin: `${summary}\n`,
    });
  }

  async deleteNode(range: Range) {
    const name = `TREE/${key(range)}.txt`;
    await this.run(
      `if [ -f ${name} ]; then git rm -q ${name}; git commit -qm "forget ${key(range)}"; fi`,
    );
  }
}

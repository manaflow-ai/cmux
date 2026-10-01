import { key, type MemoryStore, type Range } from "@mux/brain";
import { exec } from "./freestyle.ts";

/**
 * A mux's memory as a git repo on a VM: LOG.txt (one line per entry, append
 * only) and TREE/<lo>-<hi>.txt (rebuildable summaries). Every write commits.
 * Commands go through Freestyle exec; data travels on stdin or in env, never
 * in the command line.
 */
export class GitExecMemoryStore implements MemoryStore {
  private readonly dir: string;
  private ready?: Promise<void>;
  private readonly apiKey: string;
  private readonly vmId: string;

  constructor(apiKey: string, vmId: string, muxId: string) {
    this.apiKey = apiKey;
    this.vmId = vmId;
    if (!/^[A-Za-z0-9_-]+$/.test(muxId)) throw new Error(`bad mux id ${muxId}`);
    this.dir = `$HOME/mux-memory/${muxId}`;
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
    const out = await this.run(
      `python3 -c 'import json,os,re
p=re.compile(os.environ["P"],re.I);n=int(os.environ["N"]);lines=open("LOG.txt").read().split("\\n")[:-1];hits=[]
for i in range(len(lines)-1,-1,-1):
  if p.search(lines[i]): hits.append({"index":i,"line":lines[i]})
  if len(hits)>=n: break
print(json.dumps(hits))'`,
      { env: { P: pattern, N: String(limit) } },
    );
    return JSON.parse(out) as { index: number; line: string }[];
  }

  async getNodes(ranges: Range[]) {
    const found = new Map<string, string>();
    if (ranges.length === 0) return found;
    const out = await this.run(
      `python3 -c 'import json,os
out={}
for k in json.loads(os.environ["K"]):
  try: out[k]=open("TREE/"+k+".txt").read().strip()
  except FileNotFoundError: pass
print(json.dumps(out))'`,
      { env: { K: JSON.stringify(ranges.map(key)) } },
    );
    for (const [k, v] of Object.entries(JSON.parse(out) as Record<string, string>)) found.set(k, v);
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

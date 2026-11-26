/**
 * Repo-ready time for a Cloud chat opened with a folder (cloud_repos/runtime.rs "Add repository": git.seed.start with
 * no mirror and no carry), measured on the chat machine. One run times both ways git_seed (cmux-tui-core git_seed)
 * readies the folder:
 *   clone:  `git clone --filter=blob:none --no-checkout` from GitHub, then the checkout (run.rs clone_or_fetch), and
 *   borrow: a folder whose objects/info/alternates names a warm mirror on the machine, its forge a promisor, a fetch
 *           of what the mirror lacks, then the checkout (borrow.rs borrow_clone), with the clone just made as the mirror.
 * Each reports ms, the folder's .git bytes and the bytes the machine received (/proc/net/dev, every interface but lo).
 * It also reads what the guest daemon would borrow today: CMUX_SEED_MIRRORS in cmux-host's environment, whether the
 * mirror git_seed finds by default is there, and whether the image has a baked dev tree (/home/cmux/cmux).
 * CMUX_JOURNEY_REPO_SEED_RUNS=N runs it N times on the same machine (0 or unset: skipped; each run pulls the
 * repository from GitHub once).
 */
export const REPO_SEED_STEP = "repo seed (folder chat)";
export const REPO_SEED_URL = "https://github.com/manaflow-ai/cmux.git";
/** Where git_seed looks for a baked mirror when CMUX_SEED_MIRRORS is unset (borrow.rs DEFAULT_MIRRORS). */
export const REPO_SEED_DEFAULT_MIRRORS = "/opt/cmux/mirrors";

export function repoSeedRuns(value: string | undefined): number {
  const n = Number((value ?? "").trim() || "0");
  return Number.isInteger(n) && n > 0 ? Math.min(n, 5) : 0;
}

/**
 * The guest scripts, `@@seed key=value ...` lines, one per fact or phase. The clone and the borrow run as two execs,
 * each under the exec route's own 300 s cap (cloud-journey.ts directExec): in run 45597236105 the clone alone took
 * 171 s of one shared cap and the borrow never printed. `dir` is the run's folder: the clone leaves it for the borrow,
 * the borrow removes it on exit, and `cleanup` removes it when the borrow never ran.
 */
export function repoSeedScripts(dir: string, url = REPO_SEED_URL, mirrors = REPO_SEED_DEFAULT_MIRRORS): { clone: string; borrow: string; cleanup: string } {
  const head = ["set -u", `url='${url}'`, `w='${dir}'`, "rx() { awk 'NR>2 && $1 != \"lo:\" { s += $2 } END { printf \"%.0f\", s }' /proc/net/dev; }", "now() { date +%s%3N; }"];
  const clone = [
    ...head,
    "pid=$(systemctl show -p MainPID --value cmux-host.service 2>/dev/null)",
    "env_mirrors=$( { cat /proc/$pid/environ 2>/dev/null || sudo -n cat /proc/$pid/environ 2>/dev/null; } | tr '\\0' '\\n' | sed -n 's/^CMUX_SEED_MIRRORS=//p')",
    `[ -d '${mirrors}/manaflow-ai/cmux.git' ] && dm=yes || dm=no`,
    "[ -d /home/cmux/cmux/.git ] && dt=yes || dt=no",
    'echo "@@seed facts git=$(git --version | cut -d" " -f3) env_mirrors=${env_mirrors:-unset} default_mirror=$dm dev_tree=$dt free_kb=$(df -k --output=avail /tmp | tail -1 | tr -d " ")"',
    'rm -rf "$w" && mkdir -p "$w"',
    // clone, as run.rs clone_or_fetch
    "r0=$(rx); t0=$(now)",
    'git clone -q --filter=blob:none --no-checkout -- "$url" "$w/clone" 2>"$w/err"; c=$?',
    "t1=$(now); r1=$(rx)",
    'base=$(git -C "$w/clone" rev-parse HEAD 2>/dev/null)',
    'git -C "$w/clone" checkout -q --detach "$base" 2>>"$w/err"; k=$?',
    "t2=$(now); r2=$(rx)",
    'echo "@@seed clone code=$c checkout_code=$k clone_ms=$((t1-t0)) checkout_ms=$((t2-t1)) ms=$((t2-t0)) rx=$((r2-r0)) git_bytes=$(du -sb "$w/clone/.git" | cut -f1) err=$(tail -c 200 "$w/err" | tr -s "\\n " "  ")"',
    '[ "$c" = 0 ] && [ "$k" = 0 ] || rm -rf "$w"',
  ].join("\n");
  const borrow = [
    ...head,
    "trap 'rm -rf \"$w\"' EXIT",
    'base=$(git -C "$w/clone" rev-parse HEAD 2>/dev/null) || exit 0',
    // borrow, as borrow.rs borrow_clone(): init, alternates, origin a promisor, fetch what the mirror lacks, then the checkout
    "r0=$(rx); t0=$(now)",
    'git init -q -- "$w/borrow" && printf "%s\\n" "$w/clone/.git/objects" > "$w/borrow/.git/objects/info/alternates"',
    'g() { git -C "$w/borrow" "$@"; }',
    'g remote add -- origin "$url" && g config remote.origin.promisor true && g config remote.origin.partialclonefilter blob:none',
    "g config core.repositoryformatversion 1 && g config extensions.partialClone origin",
    'g fetch -q --tags origin 2>"$w/err" && g remote set-head origin --auto >/dev/null 2>>"$w/err"; f=$?',
    'miss=$(g rev-list --objects --no-walk --missing=print "$base" | grep -c "^?")',
    "t1=$(now)",
    '[ "$f" = 0 ] && g checkout -q --detach "$base" 2>>"$w/err"; k=$?',
    "t2=$(now); r2=$(rx)",
    'echo "@@seed borrow code=$k missing=$miss setup_ms=$((t1-t0)) checkout_ms=$((t2-t1)) ms=$((t2-t0)) rx=$((r2-r0)) git_bytes=$(du -sb "$w/borrow/.git" | cut -f1) err=$(tail -c 200 "$w/err" | tr -s "\\n " "  ")"',
  ].join("\n");
  return { clone, borrow, cleanup: `rm -rf '${dir}'` };
}

export type RepoSeedLine = Record<string, string>;

/** The `@@seed KIND k=v ...` lines by kind (err= takes the rest of its line). */
export function parseRepoSeed(stdout: string): Record<string, RepoSeedLine> {
  const out: Record<string, RepoSeedLine> = {};
  for (const line of stdout.split("\n")) {
    const m = /^@@seed (\w+) (.*)$/.exec(line.trim());
    if (!m) continue;
    const fields: RepoSeedLine = {};
    const [head, err] = m[2].split(/ err=/, 2);
    for (const pair of head.split(" ")) {
      const at = pair.indexOf("=");
      if (at > 0) fields[pair.slice(0, at)] = pair.slice(at + 1);
    }
    if (err !== undefined) fields.err = err.trim();
    out[m[1]] = fields;
  }
  return out;
}

const mib = (bytes: string | undefined) => (bytes && /^\d+$/.test(bytes) ? `${(Number(bytes) / 1048576).toFixed(0)} MiB` : "?");

/** One run's detail line, or the reason it failed. */
export function repoSeedDetail(parsed: Record<string, RepoSeedLine>): { ok: boolean; detail: string } {
  const f = parsed.facts;
  const c = parsed.clone;
  const b = parsed.borrow;
  const facts = f ? `env_mirrors=${f.env_mirrors} default_mirror=${f.default_mirror} dev_tree=${f.dev_tree} git=${f.git}` : "no facts";
  if (!c) return { ok: false, detail: `${facts}; the clone printed nothing` };
  if (c.code !== "0" || c.checkout_code !== "0") return { ok: false, detail: `${facts}; clone exit ${c.code}/${c.checkout_code}: ${c.err ?? ""}` };
  const clone = `clone ${c.ms} ms (fetch ${c.clone_ms} + checkout ${c.checkout_ms}), received ${mib(c.rx)}, .git ${mib(c.git_bytes)}`;
  if (!b) return { ok: false, detail: `${facts}; ${clone}; the borrow printed nothing` };
  const borrow = `borrow ${b.ms} ms (setup ${b.setup_ms} + checkout ${b.checkout_ms}), received ${mib(b.rx)}, .git ${mib(b.git_bytes)}, missing=${b.missing}`;
  return { ok: b.code === "0" && b.missing === "0", detail: `${facts}; ${clone}; ${borrow}` };
}

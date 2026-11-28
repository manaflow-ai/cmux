/**
 * The exec router's identical-result rule on a production Cloud machine: `acpmux exec-router conformance`
 * (cmux-tui/crates/acpmux/src/placement/exec_conformance.rs) run on the journey's own machine, where `acpmux run-vm`
 * really forks a run VM. Leo, 2026-11-26: "100% identical on prod". Every case runs once here and once routed and
 * must match on exit code, output and file tree, and every routed side must have run on a run VM (a routed side that
 * fell back to this machine proves nothing).
 *
 * What the machine is given, as the app's connector gives a person's Cloud machine:
 *   CMUX_CLOUD_API_URL, CMUX_CLOUD_ACCESS_TOKEN and CMUX_CLOUD_TEAM (the fork backend, sub_fork.rs CloudMachines),
 *   CMUX_VM_ID when the image did not set it, and a settings file (CMUX_NEXT_CONFIG_FILE) with AutoCloud on and run
 *   VMs on, so the run never reads or writes the machine's own settings.
 * The journey's access token lives 600 s (Api), less than the whole corpus takes, so each case is its own
 * `--case NAME` run in its own exec with a freshly minted token, and the summary is computed here the way the suite
 * computes it (exec_conformance_report.rs Summary::of).
 * `cargo-build-test` needs cargo: when the image has none, a minimal rustup toolchain is installed in $HOME first
 * (the fork copies the disk, so the run VM has it too). A case skipped for a missing program fails the step.
 * The acpmux that runs is the one this job built from journey_ref (the `--cmux` binary, which is acpmux when named so),
 * copied to JOURNEY_ACPMUX_DIR and first on PATH, so the run tests journey_ref and not whatever the image baked: run
 * 46147212934 (journey_ref 21bc3e4c) ran the image's c6cd14b59, older than the fork-path fix #64491, and every routed
 * side fell back on a fork 404. When the copy fails the image's acpmux runs and the summary says so.
 * CMUX_JOURNEY_EXEC_CONFORMANCE=1 turns the step on (unset: skipped).
 */
export const EXEC_CONFORMANCE_STEP = "exec router conformance (run VMs)";
export const EXEC_CONFORMANCE_CARGO_CASE = "cargo-build-test";

export function execConformanceOn(value: string | undefined): boolean {
  return ["1", "true", "yes", "on"].includes((value ?? "").trim().toLowerCase());
}

const q = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

/** Where the journey's own acpmux goes on the machine (fs/write runs as root and names an absolute path). */
export const JOURNEY_ACPMUX_DIR = "/home/cmux/.cmux-conformance";
/** One fs/write carries at most 8 MiB (cmux-platform MachineGuest.ts FILE_MAX_BYTES); a piece stays under it. */
export const JOURNEY_ACPMUX_PIECE_BYTES = 6 * 1024 * 1024;
/** Past this many compressed bytes the copy is not tried (a binary that big was not stripped). */
export const JOURNEY_ACPMUX_MAX_BYTES = 192 * 1024 * 1024;

/** The gzip of the journey's acpmux cut into fs/write pieces, in order. */
export function journeyAcpmuxPieces(gz: Uint8Array, pieceBytes = JOURNEY_ACPMUX_PIECE_BYTES): { path: string; data: Uint8Array }[] {
  const out: { path: string; data: Uint8Array }[] = [];
  for (let at = 0, i = 0; at < gz.length; at += pieceBytes, i++) {
    out.push({ path: `${JOURNEY_ACPMUX_DIR}/acpmux.gz.${String(i).padStart(4, "0")}`, data: gz.subarray(at, at + pieceBytes) });
  }
  return out;
}

/** Joins the pieces into JOURNEY_ACPMUX_DIR/acpmux, checks it runs, and prints its version on an @@ec line. */
export function journeyAcpmuxAssemble(pieces: number, sha256: string): string {
  const d = JOURNEY_ACPMUX_DIR;
  const parts = Array.from({ length: pieces }, (_, i) => q(`${d}/acpmux.gz.${String(i).padStart(4, "0")}`)).join(" ");
  return [
    `cat ${parts} > ${q(`${d}/acpmux.gz`)} && rm -f ${parts}`,
    `got=$(sha256sum ${q(`${d}/acpmux.gz`)} | cut -d' ' -f1); [ "$got" = ${q(sha256)} ] || { echo "@@ec journey_acpmux=bad-sum got=$got"; exit 1; }`,
    `gunzip -c ${q(`${d}/acpmux.gz`)} > ${q(`${d}/acpmux.new`)} && rm -f ${q(`${d}/acpmux.gz`)} && chmod 755 ${q(`${d}/acpmux.new`)} && mv -f ${q(`${d}/acpmux.new`)} ${q(`${d}/acpmux`)}`,
    // fs/write writes as root: the work user runs and owns it.
    `chown -R cmux:cmux ${q(d)} 2>/dev/null || true`,
    `v=$(${q(`${d}/acpmux`)} --version 2>&1 | head -1); echo "@@ec journey_acpmux=${d}/acpmux version=$v"`,
    `case "$v" in acpmux*) exit 0;; *) exit 1;; esac`,
  ].join("; ");
}

/** The guest's preamble: HOME, the acpmux binary as `$a` (the journey's own first), cargo on PATH when $HOME has it. */
const PREAMBLE = [
  'export HOME="${HOME:-/home/cmux}"',
  'cd "$HOME" 2>/dev/null || cd /',
  `export PATH="${JOURNEY_ACPMUX_DIR}:$HOME/.cargo/bin:$PATH"`,
  'a=$(command -v acpmux 2>/dev/null); [ -n "$a" ] || a=/opt/cmux/current/bin/acpmux',
].join("; ");

/** Reads the binary's version and the case names (the suite names them when asked for one it lacks), and cargo. */
export function execConformanceProbe(): string {
  return [
    PREAMBLE,
    'echo "@@ec acpmux=$a version=$("$a" --version 2>&1 | head -1)"',
    'echo "@@ec cargo=$(command -v cargo || echo none) cc=$(command -v cc || echo none)"',
    'echo "@@ec vm_id=${CMUX_VM_ID:+set} mark=$([ -e /etc/cmux ] && echo yes || echo no)"',
    '"$a" exec-router conformance --case @@none 2>&1 | head -5',
    "true",
  ].join("; ");
}

/** Installs a minimal stable toolchain in $HOME when cargo is not on PATH. */
export function execConformanceCargoInstall(): string {
  return [
    PREAMBLE,
    "cargo --version >/dev/null 2>&1 && { echo '@@ec cargo already'; exit 0; }",
    "curl -fsSL --max-time 120 https://sh.rustup.rs -o /tmp/rustup-init.sh",
    "sh /tmp/rustup-init.sh -y -q --profile minimal --default-toolchain stable --no-modify-path >/dev/null 2>&1; s=$?",
    "rm -f /tmp/rustup-init.sh",
    'echo "@@ec cargo_install exit=$s cargo=$(command -v cargo || echo none)"',
    "exit $s",
  ].join("; ");
}

/** Starts that install in the background before the acpmux upload, so the two overlap (run 46159895648: the install
 *  ran past its 300 s exec and was cut mid-toolchain, so the local side saw "rustup could not choose a version of
 *  cargo" while the routed side, run later, found the finished toolchain: cargo-build-test DIFF exit 1/0). */
export function execConformanceCargoStart(): string {
  return [
    PREAMBLE,
    "rm -f /tmp/cmux-ec-cargo.done",
    "if cargo --version >/dev/null 2>&1; then echo 0 > /tmp/cmux-ec-cargo.done; echo '@@ec cargo already'; exit 0; fi",
    `setsid nohup sh -c ${q(`( ${execConformanceCargoInstall()} ) >/tmp/cmux-ec-cargo.log 2>&1; echo $? > /tmp/cmux-ec-cargo.done`)} </dev/null >/dev/null 2>&1 & echo '@@ec cargo_install started'`,
  ].join("; ");
}

/** Waits for the background install, then proves cargo runs, so both sides of a case see one toolchain. */
export function execConformanceCargoWait(budgetSeconds = 420): string {
  return [
    PREAMBLE,
    `i=0; while [ ! -e /tmp/cmux-ec-cargo.done ] && [ $i -lt ${Math.max(1, Math.floor(budgetSeconds / 5))} ]; do sleep 5; i=$((i+1)); done`,
    "cargo --version >/dev/null 2>&1 || rustup default stable >/dev/null 2>&1",
    'v=$(cargo --version 2>&1 | head -1)',
    'echo "@@ec cargo_ready=$(cargo --version >/dev/null 2>&1 && echo yes || echo no) install_exit=$(cat /tmp/cmux-ec-cargo.done 2>/dev/null || echo unfinished) waited_s=$((i*5)) version=$v"',
    "cargo --version >/dev/null 2>&1 || tail -5 /tmp/cmux-ec-cargo.log 2>/dev/null",
  ].join("; ");
}

export type ExecConformanceEnv = { api: string; token: string; team?: string | null; machine: string };

/** One case's run: the fork backend's variables, AutoCloud and run VMs on in a settings file of its own. */
export function execConformanceCase(name: string, env: ExecConformanceEnv, dir: string): string {
  return [
    PREAMBLE,
    "umask 077",
    `d=${q(dir)}`,
    'mkdir -p "$d"',
    `printf '%s\\n' '{"cloud.autoCloud": true, "cloud.runVms": true}' > "$d/cmux-next.json"`,
    'export CMUX_NEXT_CONFIG_FILE="$d/cmux-next.json"',
    "unset CMUX_RUN_VMS CMUX_EXEC_ROUTE",
    `export CMUX_CLOUD_API_URL=${q(env.api)}`,
    `export CMUX_CLOUD_ACCESS_TOKEN=${q(env.token)}`,
    env.team ? `export CMUX_CLOUD_TEAM=${q(env.team)}` : "unset CMUX_CLOUD_TEAM",
    `export CMUX_VM_ID="\${CMUX_VM_ID:-${env.machine.replace(/[^A-Za-z0-9_-]/g, "")}}"`,
    `"$a" --json exec-router conformance --case ${q(name)}; echo "@@ec exit=$?"`,
  ].join("; ");
}

/** The case names from the suite's own refusal of an unknown case: "no such case: X (the cases: a, b, c)". */
export function parseCaseNames(out: string): string[] {
  const m = out.match(/the cases: ([^)]*)\)/);
  return m ? m[1].split(",").map((s) => s.trim()).filter(Boolean) : [];
}

export type ConformanceRow = {
  case: string;
  identical: boolean;
  diffs?: string[];
  skipped?: string;
  routedRan?: string;
  routedCause?: string;
  exit?: { local: number; routed: number };
  [k: string]: unknown;
};

/** The rows of one or more `--json` runs: each line that is a row (it names a case); the run's own summary is not one. */
export function parseRows(out: string): ConformanceRow[] {
  const rows: ConformanceRow[] = [];
  for (const line of out.split("\n")) {
    const t = line.trim();
    if (!t.startsWith("{")) continue;
    try {
      const v = JSON.parse(t);
      if (v && typeof v.case === "string" && typeof v.identical === "boolean") rows.push(v);
    } catch {
      // not a row
    }
  }
  return rows;
}

export type ConformanceVerdict = {
  ok: boolean;
  line: string;
  total: number;
  identical: number;
  onRunVm: number;
  unexpected: string[];
  notRouted: string[];
  skipped: string[];
  missing: string[];
  cargo: string;
};

/** Summary::of over every case's row, stricter in two ways: a skipped case and a case with no row both fail. */
export function verdict(cases: string[], rows: ConformanceRow[]): ConformanceVerdict {
  const byCase = new Map(rows.map((r) => [r.case, r]));
  const v: ConformanceVerdict = { ok: false, line: "", total: 0, identical: 0, onRunVm: 0, unexpected: [], notRouted: [], skipped: [], missing: [], cargo: "no row" };
  for (const name of cases) {
    const r = byCase.get(name);
    if (!r) { v.missing.push(name); continue; }
    if (r.skipped) { v.skipped.push(name); continue; }
    v.total += 1;
    if (r.identical) v.identical += 1; else v.unexpected.push(name);
    if (r.routedRan === "fork") v.onRunVm += 1; else v.notRouted.push(name);
  }
  const c = byCase.get(EXEC_CONFORMANCE_CARGO_CASE);
  if (c) v.cargo = rowText(c);
  v.ok = cases.length > 0 && v.total === cases.length && v.unexpected.length === 0 && v.notRouted.length === 0;
  const parts = [`identical ${v.identical}/${v.total}; on a run VM ${v.onRunVm}/${v.total}`];
  if (v.unexpected.length) parts.push(`UNEXPECTED: ${v.unexpected.join(", ")}`);
  if (v.notRouted.length) parts.push(`routed side ran here (proves nothing): ${v.notRouted.join(", ")}`);
  if (v.skipped.length) parts.push(`skipped: ${v.skipped.join(", ")}`);
  if (v.missing.length) parts.push(`no row: ${v.missing.join(", ")}`);
  v.line = parts.join("; ");
  return v;
}

/** One row as one line: case, verdict, where the routed side ran, exits, and what differed. */
export function rowText(r: ConformanceRow): string {
  if (r.skipped) return `${r.case}: skipped (${r.skipped})`;
  const exit = r.exit ? ` exit ${r.exit.local}/${r.exit.routed}` : "";
  const diffs = r.diffs?.length ? ` diffs ${r.diffs.join(",")}` : "";
  const cause = r.routedCause ? ` (${String(r.routedCause).slice(0, 160)})` : "";
  return `${r.case}: ${r.identical ? "identical" : "DIFF"}, routed ran ${r.routedRan ?? "?"}${cause}${exit}${diffs}`;
}

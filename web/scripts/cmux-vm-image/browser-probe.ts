/**
 * Browser role probe for a cmux VM image clone (plans/cmux-next/cloud-automation.md 31; RT8, D-A1).
 *
 * 1. User namespaces: the work user can make a user namespace (Chrome's namespace sandbox needs
 *    it; the image never installs a setuid sandbox and never passes --no-sandbox).
 * 2. First-use install of the browser role, as `cmux host` will do it: the exact apt closure from
 *    the dated snapshot (own source file and lists directory; the live sources stay untouched),
 *    then each first-use program into its store entry (sha256 and size checked). The packages the
 *    install added must equal the locked closure.
 * 3. Chrome runs sandboxed as the work user: a renderer sits in its own user namespace with
 *    seccomp filter mode, and the browser command line has no sandbox-off switch.
 * 4. When the role carries cmux-browser-host: `version` names the pinned commit, the notices sit
 *    next to the binary, `serve` on a socket, `eval` opens a loopback page and takes a snapshot,
 *    `list` shows no session, then the host's whole process session is measured idle.
 * Commands run under /bin/sh (dash) as the provider's exec does: no bash-only syntax. Output that
 * Chrome's children could hold open goes to files, never through $(...).
 *
 * Standalone (from web/), before a bake carries the role:
 *   bun scripts/cmux-vm-image/browser-probe.ts --snapshot <sh-id> --tag <tag> [--from-lock] [--idle-seconds 60]
 * --from-lock installs from this checkout's lock instead of the clone's /etc/cmux/roles.json.
 * The clone is named cmuxnp-dev-vmimg-<tag>-browser, recorded in <out-dir>/resources.tsv and deleted.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run, type Vm } from "./guest";
import { aptClosureProblems, DEFAULT_LOCK_PATH, programInstallCommand, readInputsLock, type RoleManifestEntry, ROLES_MANIFEST_PATH, rolesManifest, type RolesManifest, sq } from "./lock";

export const BROWSER_ROLE = "browser";
const APT_DIR = "/var/lib/cmux/apt-snapshot";
/** The host opens only absolute http(s) URLs, so the probe serves its page on loopback. */
const PAGE_PORT = 18731;
const PAGE_URL = `http://127.0.0.1:${PAGE_PORT}/`;
const PAGE_HTML = "<!doctype html><title>cmux</title><h1>cmux browser role</h1>";
const PAGE_TEXT = "cmux browser role";

export type ProbeCheck = { ok: boolean; detail: string };
export type BrowserProbeResult = { checks: Record<string, ProbeCheck>; timings: Record<string, number>; idle?: Record<string, number | string>; pending: string[] };

/** Prints the kernel switches and tries an unprivileged user namespace as the work user. */
export function userNamespaceCheckCommand(): string {
  return [
    `printf 'max_user_namespaces=%s\\n' "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo absent)"`,
    `printf 'unprivileged_userns_clone=%s\\n' "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo absent)"`,
    `printf 'apparmor_restrict_unprivileged_userns=%s\\n' "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo absent)"`,
    `if sudo -n -u ${DEVBOX_WORK_USER} -H unshare --user --map-root-user --pid --fork --mount-proc true; then echo userns=ok; else echo userns=refused; fi`,
  ].join("; ");
}

/** apt options that read only the dated snapshot, with its own lists directory. */
function snapshotAptOptions(): string {
  return `-o Dir::Etc::sourcelist=${APT_DIR}/snapshot.sources -o Dir::Etc::sourceparts=${APT_DIR}/parts -o Dir::State::Lists=${APT_DIR}/lists`;
}

/** One exec stays under the provider's 5 minute limit; the install runs as phases. */
export const EXEC_LIMIT_MS = 290_000;

/**
 * The first-use install of one role (as root), as ordered phases (one exec each): the exact apt
 * closure from the snapshot (prints `ADDED<TAB>name<TAB>version` per package it added), then each
 * first-use program into its store entry.
 */
export function firstUseInstallPhases(manifest: RolesManifest, role: string): Array<{ name: string; command: string }> {
  const entry = manifest.roles[role];
  const closure = manifest.firstUse[role] ?? {};
  const pins = Object.entries(closure).sort(([a], [b]) => a.localeCompare(b)).map(([n, v]) => sq(`${n}=${v}`)).join(" ");
  const sources = Buffer.from(manifest.aptSources).toString("base64");
  const dpkg = "dpkg-query -W -f='${Package}\\t${Version}\\n' | LC_ALL=C sort";
  const apt = [
    `mkdir -p ${APT_DIR}/lists/partial ${APT_DIR}/parts`,
    `printf '%s' ${sq(sources)} | base64 -d > ${APT_DIR}/snapshot.sources`,
    `${dpkg} > ${APT_DIR}/before.tsv`,
    `{ apt-get ${snapshotAptOptions()} update -q >${APT_DIR}/update.log 2>&1 || { tail -20 ${APT_DIR}/update.log; false; }; }`,
    `{ DEBIAN_FRONTEND=noninteractive apt-get ${snapshotAptOptions()} install -y --no-install-recommends ${pins} >${APT_DIR}/install.log 2>&1 || { tail -30 ${APT_DIR}/install.log; false; }; }`,
    `${dpkg} > ${APT_DIR}/after.tsv`,
    `LC_ALL=C comm -13 ${APT_DIR}/before.tsv ${APT_DIR}/after.tsv | sed 's/^/ADDED\\t/'`,
  ].join(" && ");
  return [
    { name: "apt-install", command: apt },
    ...entry.programs.map((p) => ({ name: `program-${p.name}`, command: `{ ${programInstallCommand(p)}; } >/tmp/cmux-dl-${p.name}.log 2>&1 || { tail -20 /tmp/cmux-dl-${p.name}.log; false; }` })),
  ];
}

/** Problems when the install added other packages than the locked closure. */
export function installProblems(manifest: RolesManifest, role: string, stdout: string): string[] {
  const added = new Map<string, string>();
  for (const line of stdout.split("\n")) {
    const [tag, name, version] = line.split("\t");
    if (tag === "ADDED" && name && version) added.set(name, version);
  }
  return aptClosureProblems(manifest.firstUse[role] ?? {}, added);
}

/** Env assignments for a role's processes (shell-quoted). */
function envPrefix(env: Readonly<Record<string, string>>): string {
  return Object.entries(env).map(([k, v]) => `${k}=${sq(v)}`).join(" ");
}

/**
 * As the work user: start headless Chrome in its own session, find a renderer of that session,
 * compare its user namespace with the browser's, read its seccomp mode, and check the browser
 * command line. (`--dump-dom` hangs on this image even for about:blank; the page check goes
 * through the host instead, which is the path agents use.)
 */
export function chromeSandboxCommand(entry: RoleManifestEntry): string {
  const chrome = entry.env.CMUX_BROWSER_HOST_CHROMIUM;
  return [
    `d=$(mktemp -d); export ${envPrefix(entry.env)}`,
    // A DevTools pipe, never a port (cx-2u5k: no cmux process opens a loopback DevTools port on a
    // machine). fd 3 is an open FIFO that never carries a message, so Chrome stays up; fd 4 is unread.
    `mkfifo "$d/cdp" && exec 9<>"$d/cdp"`,
    `setsid ${sq(chrome)} --headless --no-first-run --user-data-dir="$d/p1" --remote-debugging-pipe about:blank 3<&9 4>/dev/null >"$d/chrome.log" 2>&1 & b=$!`,
    // Test-side wait (bounded) for the renderer process to exist.
    `r=""; for i in $(seq 1 100); do r=$(pgrep -s "$b" -f -- '--type=renderer' | head -1); [ -n "$r" ] && break; sleep 0.1; done`,
    `echo "renderer=\${r:-none}"`,
    `echo "browser_userns=$(readlink /proc/$b/ns/user)"`,
    `[ -n "$r" ] && echo "renderer_userns=$(readlink /proc/$r/ns/user)" && echo "renderer_seccomp=$(awk '/^Seccomp:/{print $2}' /proc/$r/status)"`,
    `if tr '\\0' ' ' < /proc/$b/cmdline | grep -qE -- '--no-sandbox|--disable-setuid-sandbox'; then echo browser_args=sandbox-off; else echo browser_args=sandbox-on; fi`,
    `kill -- -"$b" 2>/dev/null; wait "$b" 2>/dev/null`,
    `grep -m3 -iE 'sandbox|fatal' "$d/chrome.log" | sed 's/^/LOG /'`,
    `exec 9>&-; pkill -f -- "$d/" 2>/dev/null; rm -rf "$d"`,
  ].join("\n");
}

/** Sum of utime+stime ticks of every process in session `$1` (the host and its Chrome tree). */
const SESSION_TICKS = `ticks() { local s=0 f st; for f in /proc/[0-9]*/stat; do st=$(cat "$f" 2>/dev/null) || continue; st=\${st##*) }; set -- $st; [ "$4" = "$SID" ] && s=$((s + \${12} + \${13})); done; echo $s; }`;

/** As the work user: serve, open a loopback page and snapshot it through the host, list, then measure idle. */
export function hostSessionCommand(entry: RoleManifestEntry, idleSeconds: number): string {
  const host = entry.programs.find((p) => p.name === "cmux-browser-host");
  if (!host) throw new Error("the browser role has no cmux-browser-host program");
  const dir = host.storeEntry;
  const bin = `${dir}/${host.bin["cmux-browser-host"]}`;
  const js = `await page.goto(${JSON.stringify(PAGE_URL)}); snapshot()`;
  return [
    `d=$(mktemp -d); export ${envPrefix(entry.env)}`,
    `echo "version=$(${sq(bin)} version)"`,
    `echo "notices=$(for n in ${(host.notices ?? []).map(sq).join(" ")}; do test -s ${sq(dir)}/"$n" && printf '%s ' "$n"; done)"`,
    `mkdir -p "$d/www" && printf '%s' ${sq(PAGE_HTML)} > "$d/www/index.html"`,
    `setsid python3 -m http.server ${PAGE_PORT} --bind 127.0.0.1 --directory "$d/www" >"$d/www.log" 2>&1 & W=$!`,
    `setsid ${sq(bin)} serve --socket "$d/h.sock" >"$d/serve.log" 2>&1 & SID=$!`,
    `for i in $(seq 1 100); do [ -S "$d/h.sock" ] && break; sleep 0.1; done; [ -S "$d/h.sock" ] || { echo "FAIL serve"; tail -5 "$d/serve.log"; exit 1; }`,
    `t=$(date +%s%3N); timeout 120 ${sq(bin)} eval --socket "$d/h.sock" ${sq(js)} >"$d/eval.out" 2>&1 </dev/null; echo "eval_exit=$?"; echo "eval_ms=$(( $(date +%s%3N) - t ))"`,
    `tr '\\n' ' ' < "$d/eval.out" | head -c 600; echo`,
    `${sq(bin)} list --socket "$d/h.sock" >"$d/list.out" 2>&1; echo "list=$(tr -d ' \\n' < "$d/list.out")"`,
    SESSION_TICKS,
    // Let a closed one-shot session's tabs and engine wind down before the idle window.
    "sleep 5",
    // One key=value per line (the parser reads each line as one pair).
    `echo "procs_before=$(pgrep -s "$SID" | wc -l)"; echo "chrome_before=$(pgrep -s "$SID" -f chrome | wc -l)"`,
    `a=$(ticks); sleep ${idleSeconds}; b=$(ticks); echo "ticks_a=$a"; echo "idle_ticks=$((b - a))"; echo "clk_tck=$(getconf CLK_TCK)"`,
    `echo "procs_after=$(pgrep -s "$SID" | wc -l)"; echo "chrome_after=$(pgrep -s "$SID" -f chrome | wc -l)"`,
    `tail -5 "$d/serve.log" | cut -c1-200 | sed 's/^/SERVELOG /'`,
    `kill -- -"$SID" -"$W" 2>/dev/null; pkill -f -- "$d/" 2>/dev/null; rm -rf "$d"`,
  ].join("\n");
}

const kv = (text: string) => Object.fromEntries(text.split("\n").filter((l) => /^[a-z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));

/** The roles manifest on the clone (after a bake) or from this checkout's lock (--from-lock). */
async function manifestFor(vm: Vm, lockPath: string, fromLock: boolean): Promise<RolesManifest> {
  const local = rolesManifest(readInputsLock(lockPath));
  if (fromLock) return local;
  const r = await run(vm, `cat ${ROLES_MANIFEST_PATH}`);
  const guest = JSON.parse(r.stdout) as RolesManifest;
  if (JSON.stringify(guest) !== JSON.stringify(local)) throw new Error(`${ROLES_MANIFEST_PATH} on the clone differs from the lock's roles manifest`);
  return guest;
}

export async function browserRoleProbe(vm: Vm, options: { lockPath: string; fromLock?: boolean; idleSeconds?: number }): Promise<BrowserProbeResult> {
  const result: BrowserProbeResult = { checks: {}, timings: {}, pending: [] };
  const check = (name: string, ok: boolean, detail: string) => {
    result.checks[name] = { ok, detail };
    console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${detail.slice(0, 400)}`);
  };
  const manifest = await manifestFor(vm, options.lockPath, options.fromLock === true);
  const entry = manifest.roles[BROWSER_ROLE];
  if (!entry) throw new Error("the lock has no browser role");
  check("browser-role-off", entry.default === "off" && entry.firstUse, JSON.stringify({ default: entry.default, firstUse: entry.firstUse }));
  check("browser-background-throttled", entry.env.CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE === "0", JSON.stringify(entry.env));
  const before = await run(vm, `command -v chrome; test -e ${entry.env.CMUX_BROWSER_HOST_CHROMIUM} && echo chrome-present; dpkg-query -W -f='\${Status}' libnss3 2>/dev/null | grep -q 'ok installed' && echo libnss3-present; true`);
  check("browser-not-baked", before.stdout.trim() === "", before.stdout.trim() || "no chrome in the store or on PATH, libnss3 not installed");

  const userns = kv((await run(vm, userNamespaceCheckCommand())).stdout);
  check("userns-work-user", userns.userns === "ok", JSON.stringify(userns));

  const t0 = Date.now();
  let failed: string | null = null;
  let aptOut = "";
  for (const phase of firstUseInstallPhases(manifest, BROWSER_ROLE)) {
    const r = await run(vm, phase.command, EXEC_LIMIT_MS);
    result.timings[`${phase.name}Ms`] = r.ms;
    if (phase.name === "apt-install") aptOut = r.stdout;
    if (r.code !== 0) {
      failed = `${phase.name}: exit ${r.code} ${r.stdout.slice(-600)} ${r.stderr.slice(-300)}`;
      break;
    }
  }
  result.timings.firstUseInstallMs = Date.now() - t0;
  const problems = failed ? [] : installProblems(manifest, BROWSER_ROLE, aptOut);
  check("first-use-install", !failed && problems.length === 0, failed ?? (problems.join("; ") || `closure equals the lock (${Object.keys(manifest.firstUse[BROWSER_ROLE] ?? {}).length} packages), ${entry.programs.map((p) => p.name).join(", ")} in the store`));
  if (failed) return result;

  const chrome = await run(vm, `ldd ${entry.env.CMUX_BROWSER_HOST_CHROMIUM} | grep 'not found' || echo all-found; ${sq(entry.env.CMUX_BROWSER_HOST_CHROMIUM)} --version`, 60_000, DEVBOX_WORK_USER);
  const cft = entry.programs.find((p) => p.name === "chrome-for-testing");
  check("chrome-libraries-and-version", chrome.stdout.includes("all-found") && Boolean(cft && chrome.stdout.includes(`Google Chrome for Testing ${cft.version}`)), chrome.stdout.trim().replace(/\n/g, " | "));

  const sandbox = await run(vm, chromeSandboxCommand(entry), 120_000, DEVBOX_WORK_USER);
  const s = kv(sandbox.stdout);
  const sandboxed = s.renderer !== "none" && Boolean(s.renderer_userns) && s.renderer_userns !== s.browser_userns && s.renderer_seccomp === "2" && s.browser_args === "sandbox-on";
  check("chrome-sandboxed", sandboxed, JSON.stringify({ renderer_userns_differs: s.renderer_userns !== s.browser_userns, renderer_seccomp: s.renderer_seccomp, browser_args: s.browser_args, log: sandbox.stdout.split("\n").filter((l) => l.startsWith("LOG ")).join(" ") }));

  if (entry.programs.some((p) => p.name === "cmux-browser-host")) {
    const idleSeconds = options.idleSeconds ?? 60;
    const host = await run(vm, hostSessionCommand(entry, Math.min(idleSeconds, 150)), EXEC_LIMIT_MS, DEVBOX_WORK_USER);
    const h = kv(host.stdout);
    const hostProgram = entry.programs.find((p) => p.name === "cmux-browser-host");
    check("host-version", Boolean(hostProgram && h.version?.startsWith(`cmux-browser-host ${hostProgram.version} (`)), `version=${h.version}`);
    check("host-notices", (hostProgram?.notices ?? []).every((n) => (h.notices ?? "").split(" ").includes(n)), `notices=${h.notices}`);
    check("host-page-snapshot", h.eval_exit === "0" && host.stdout.includes(PAGE_TEXT), `eval_exit=${h.eval_exit} eval_ms=${h.eval_ms} ${host.stdout.split("\n").filter((l) => !/^[a-z_]+=/.test(l)).join(" ").slice(0, 700)} ${host.stderr.slice(-200)}`);
    check("host-list-empty", h.list === "[]", `list=${h.list}`);
    const cpuSecPerMin = (Number(h.idle_ticks) / Number(h.clk_tck)) * (60 / idleSeconds);
    result.idle = { cpuSecPerMin, procsBefore: h.procs_before, chromeBefore: h.chrome_before, procsAfter: h.procs_after, chromeAfter: h.chrome_after, evalMs: Number(h.eval_ms) };
    check("host-idle-cpu", Number.isFinite(cpuSecPerMin) && Number(h.ticks_a) > 0, `${cpuSecPerMin.toFixed(4)} CPU-s/min over ${idleSeconds} s with no session (host + Chrome tree)`);
  } else {
    result.pending.push("cmux-browser-host: no release pinned yet (serve, page through the host, snapshot, idle CPU with no session)");
    console.log(`PENDING ${result.pending.at(-1)}`);
  }
  return result;
}

export async function main(argv = process.argv): Promise<number> {
  const snapshotId = argValue("--snapshot", argv);
  const tag = argValue("--tag", argv);
  if (!snapshotId?.startsWith("sh-") || !tag) throw new Error("usage: browser-probe.ts --snapshot <sh-id> --tag <tag> [--from-lock] [--idle-seconds 60] [--out-dir <dir>]");
  const outDir = path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${tag}-browser`);
  mkdirSync(outDir, { recursive: true });
  const ledger = new Ledger(path.join(outDir, "resources.tsv"));
  const name = `cmuxnp-dev-vmimg-${tag}-browser`;
  const { vm, vmId, t0 } = await createVm(freestyleClient(), ledger, { name, snapshotId });
  let result: BrowserProbeResult | null = null;
  let error: string | null = null;
  try {
    await firstExec(vm, t0);
    result = await browserRoleProbe(vm, { lockPath: path.resolve(argValue("--lock", argv) ?? DEFAULT_LOCK_PATH), fromLock: argv.includes("--from-lock"), idleSeconds: Number(argValue("--idle-seconds", argv) ?? 60) });
  } catch (e) {
    error = String(e);
    console.error(`BROWSER PROBE FAILED: ${error}`);
  } finally {
    await deleteVm(vm, vmId, name, ledger);
  }
  const passed = !error && result !== null && Object.values(result.checks).every((c) => c.ok);
  writeFileSync(path.join(outDir, `browser-probe-${tag}.json`), `${JSON.stringify({ snapshotId, vmId, passed, error, ...result }, null, 2)}\n`);
  console.log(passed ? "BROWSER PROBE PASSED" : "BROWSER PROBE FAILED");
  return passed ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());

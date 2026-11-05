#!/usr/bin/env bun
/**
 * Loop A of the NEXT Cloud inner loop: one persistent Cloud machine is the dev box. Each run builds this worktree's
 * machine-side binary on a warm fleet Linux checkout, puts it on the machine, restarts the units that run it, and runs
 * the Cloud journey on that same machine, printing the first failing step with the machine's journal lines.
 *
 *   bun scripts/cmux-next/cloud-devloop.ts --credentials ~/.secrets/cmuxterm-prod.env            # build, push, journey
 *   bun scripts/cmux-next/cloud-devloop.ts --credentials F --no-build -- --keyed-start            # journey only, its flags after --
 *   bun scripts/cmux-next/cloud-devloop.ts --credentials F --restore                              # back to the image's binary
 *   bun scripts/cmux-next/cloud-devloop.ts --credentials F --snapshot                             # the dev machine as an image
 *
 * Flags: --machine NAME|vm_ID (default cloud-devloop; made on first use), --backend prod|staging|... (default prod),
 * --build-host HOST (or CLOUD_DEVLOOP_BUILD_HOST: an ssh host with cargo, zig at /opt/zig-*, bun, zstd), --no-build, --no-push,
 * --no-journey, --units host,acpmux (what to restart; default both), --restore, --snapshot.
 *
 * What runs where:
 *   1. sync: the files this worktree changed against its merge base with origin/feat-cmux-next (committed, staged,
 *      unstaged, untracked) go by rsync to the build host's checkout of that base (~/Projects/lane-scratch/cloud-devloop/cmux,
 *      reset to the base when the base moves). Its cargo target stays warm between runs.
 *   2. build: `cargo build -p cmux-tui --bin cmux-tui` (dev profile: opt 1 for our crates, 3 for deps; stripped, no
 *      DWARF; zig's libghostty-vt for a baseline CPU, as the builder's native one SIGILLs on the guest) for x86_64-unknown-linux-gnu. The guest is Ubuntu 24.04 like the builder, so no musl cross build. cmux-tui
 *      is the machine's one multi-call binary: /opt/cmux/current/bin/{cmux-tui,cmux,acpmux} are all it.
 *   3. push: zstd --patch-from the binary this machine runs from the last push (about 6 MB after a one-crate edit; the
 *      whole 60 MB the first time), uploaded from the build host in 512 KiB fs/write pieces (the machine routes take
 *      under 768 KiB per write), checked by SHA-256 on the machine.
 *   4. install: a profile /opt/cmux/profiles/devloop-<sha12> that is the image's profile with those three links on the
 *      new binary, /opt/cmux/current flipped to it (one rename), ~/.cmux/bin/cmux-tui pointed through current, then
 *      `systemctl restart cmux-host.service` (host and session daemon; terminal hosts keep running in their own scopes)
 *      and the user's acpmux.service.
 *   5. journey: scripts/cmux-next/cloud-journey.ts --machine <it> (no create, pause or delete), with --model stub
 *      unless the words after `--` choose; on a red step, the journal of cmux-host and acpmux since the run began.
 *
 * Credentials: the agent test account (CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD, or --credentials FILE). The build host gets
 * only a short-lived session token, on its stdin, never in argv or a file. Nothing secret is printed.
 */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readEnvFile, resolveBackend, scrub, STACK, STACK_API } from "./cloud-journey.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
export const REMOTE_DIR = "Projects/lane-scratch/cloud-devloop/cmux";
export const GUEST_DIR = "/home/cmux/.cache/cloud-devloop";
/** Under the machine routes' per-write limit: the provider takes at most 1 MiB of base64 exec stdin (768 KiB decoded), fs/write's carrier. */
export const PIECE_BYTES = 512 * 1024;
const BASE_BRANCH = "origin/feat-cmux-next";

const argValue = (name: string, argv: string[]) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const now = () => performance.now();
const secs = (t0: number) => ((now() - t0) / 1000).toFixed(1);
export const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

function sh(cmd: string, args: string[], opts: { input?: string; cwd?: string; quiet?: boolean; timeoutMs?: number } = {}): { code: number; out: string; err: string } {
  const r = spawnSync(cmd, args, { cwd: opts.cwd ?? root, input: opts.input, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, timeout: opts.timeoutMs ?? 30 * 60_000 });
  if (r.error) throw r.error;
  return { code: r.status ?? 1, out: r.stdout ?? "", err: r.stderr ?? "" };
}
function must(what: string, r: { code: number; out: string; err: string }): string {
  if (r.code !== 0) throw new Error(`${what} failed (exit ${r.code}): ${(r.err || r.out).trim().split("\n").slice(-15).join("\n")}`);
  return r.out;
}

/** The files to sync: changed against `base` (any state), untracked, and the deleted ones apart. */
export function changedFiles(nameStatus: string, untracked: string): { copy: string[]; removed: string[] } {
  const copy = new Set<string>();
  const removed = new Set<string>();
  for (const line of nameStatus.split("\n")) {
    if (!line.trim()) continue;
    const parts = line.split("\t");
    const status = parts[0];
    if (status.startsWith("R") || status.startsWith("C")) {
      if (status.startsWith("R")) removed.add(parts[1]);
      copy.add(parts[2]);
    } else if (status === "D") removed.add(parts[1]);
    else copy.add(parts[1]);
  }
  for (const f of untracked.split("\n")) if (f.trim()) copy.add(f.trim());
  for (const f of copy) removed.delete(f);
  return { copy: [...copy].sort(), removed: [...removed].sort() };
}

/** The bash the build host runs to put its checkout at `base` with exactly this run's changes over it. */
export function remotePrepareScript(base: string, removed: string[]): string {
  return [
    "set -euo pipefail",
    `cd ~/${REMOTE_DIR}`,
    `base=${shq(base)}`,
    'if [ "$(git rev-parse HEAD)" != "$base" ]; then',
    '  git cat-file -e "$base^{commit}" 2>/dev/null || git fetch -q origin "$base" || git fetch -q origin feat-cmux-next',
    '  git checkout -q -f "$base"',
    '  git submodule update -q --init --depth 1 ghostty-next',
    "fi",
    // Whatever the last run applied that this one does not: back to the base (or gone, if the base has no such file).
    "applied=.git/devloop-applied",
    "touch $applied",
    'while IFS= read -r f; do [ -z "$f" ] && continue; if git cat-file -e "HEAD:$f" 2>/dev/null; then git checkout -q HEAD -- "$f"; else rm -f -- "$f"; fi; done < $applied',
    ...removed.map((f) => `rm -f -- ${shq(f)}`),
    "echo prepared",
  ].join("\n");
}

class Cloud {
  bearer = "";
  readonly secrets: string[] = [];
  constructor(readonly api: string, readonly stack: keyof typeof STACK) {}
  async signIn(email: string, password: string) {
    this.secrets.push(password);
    const s = STACK[this.stack];
    const r = await fetch(`${STACK_API}/api/v1/auth/password/sign-in`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-stack-access-type": "client", "x-stack-project-id": s.project, ...(s.clientKey ? { "x-stack-publishable-client-key": s.clientKey } : {}) },
      body: JSON.stringify({ email, password }),
    });
    const body: any = await r.json().catch(() => ({}));
    if (r.status !== 200 || typeof body.access_token !== "string") throw new Error(`Stack sign-in HTTP ${r.status} ${body.code ?? ""}`);
    this.bearer = body.access_token;
    this.secrets.push(body.access_token, body.refresh_token ?? "");
  }
  private async call(method: string, route: string, body?: unknown, timeoutMs = 60_000): Promise<{ status: number; body: any }> {
    const r = await fetch(`${this.api}${route}`, {
      method,
      headers: { authorization: `Bearer ${this.bearer}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
    return { status: r.status, body: await r.json().catch(() => ({})) };
  }
  async read(op: string, params: unknown) {
    const r = await this.call("POST", "/v1/read", { op, params });
    if (r.status !== 200 || r.body.ok === false) throw new Error(`${op}: HTTP ${r.status} ${JSON.stringify(r.body.error ?? r.body).slice(0, 300)}`);
    return r.body.value;
  }
  async op(op: string, params: unknown) {
    const r = await this.call("POST", "/v1/ops", { op, params, idempotency_key: `devloop-${op}-${Date.now()}` });
    if (r.status !== 200 || r.body.ok !== true) throw new Error(`${op}: HTTP ${r.status} ${JSON.stringify(r.body.error ?? r.body).slice(0, 300)}`);
    return r.body.value;
  }
  /** The machine exec route, as the work user (sudo -n for root). */
  async exec(machine: string, command: string, timeoutMs = 120_000): Promise<{ code: number; stdout: string; stderr: string }> {
    const r = await this.call("POST", `/v1/cloud/machines/${machine}/exec`, { command, timeoutMs }, timeoutMs + 30_000);
    const v = r.body?.value ?? r.body;
    if (r.status < 200 || r.status >= 300 || v?.ok === false) throw new Error(`exec: HTTP ${r.status} ${JSON.stringify(v?.error ?? v).slice(0, 300)}`);
    return { code: Number(v.exitCode ?? v.exit_code ?? 1), stdout: String(v.stdout ?? ""), stderr: String(v.stderr ?? "") };
  }
  async write(machine: string, file: string, data: Uint8Array, mode = 0o644): Promise<void> {
    const r = await this.call("POST", `/v1/cloud/machines/${machine}/fs/write`, { path: file, dataBase64: Buffer.from(data).toString("base64"), mode }, 120_000);
    if (r.status < 200 || r.status >= 300 || r.body?.ok === false) throw new Error(`fs/write ${file}: HTTP ${r.status} ${JSON.stringify(r.body?.error ?? r.body).slice(0, 200)}`);
  }
}

/** Upload `data` to the machine as numbered pieces under `dir`, `parallel` at a time, each retried. */
export async function uploadPieces(cloud: Pick<Cloud, "write">, machine: string, dir: string, data: Uint8Array, parallel = 8): Promise<number> {
  const pieces: Array<[string, Uint8Array]> = [];
  for (let at = 0, i = 0; at < data.byteLength; at += PIECE_BYTES, i++) pieces.push([`${dir}/${String(i).padStart(5, "0")}`, data.subarray(at, at + PIECE_BYTES)]);
  let next = 0;
  const worker = async () => {
    while (next < pieces.length) {
      const [file, bytes] = pieces[next++];
      for (let attempt = 1; ; attempt++) {
        try { await cloud.write(machine, file, bytes); break; } catch (error) { if (attempt >= 4) throw error; await Bun.sleep(500 * attempt); }
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(parallel, pieces.length) }, worker));
  return pieces.length;
}

/** The guest's install: reassemble, check, make the dev profile, flip current, restart. Runs as the work user. */
export function guestInstallScript(sha: string, mode: "patch" | "full", units: string[]): string {
  const short = sha.slice(0, 12);
  return [
    "set -euo pipefail",
    `D=${GUEST_DIR}; cd "$D"`,
    `cat in/* > blob; rm -rf in`,
    mode === "patch"
      ? `"$D/zstd" -d -q -f --long=28 --patch-from=current.bin blob -o new.bin`
      : `"$D/zstd" -d -q -f --long=28 blob -o new.bin`,
    "rm -f blob",
    `echo ${shq(`${sha}  new.bin`)} | sha256sum -c --quiet`,
    "chmod 755 new.bin && mv -f new.bin current.bin",
    // The image's own profile is remembered once, so --restore always has it.
    `[ -s original-profile ] || readlink /opt/cmux/current > original-profile`,
    `orig="/opt/cmux/$(cat original-profile)"`,
    `P=/opt/cmux/profiles/devloop-${short}`,
    `sudo -n install -D -m 755 current.bin /opt/cmux/devloop/cmux-tui-${short}`,
    // cp -a keeps the image profile's mtime: touch it, or the prune below sorts it among the oldest.
    `sudo -n rm -rf "$P" && sudo -n cp -a "$orig" "$P" && sudo -n touch "$P"`,
    `for n in cmux-tui cmux acpmux; do sudo -n ln -sfn /opt/cmux/devloop/cmux-tui-${short} "$P/bin/$n"; done`,
    `sudo -n ln -sfn "profiles/devloop-${short}" /opt/cmux/current.devloop && sudo -n mv -Tf /opt/cmux/current.devloop /opt/cmux/current`,
    // The session daemon runs ~/.cmux/bin/cmux-tui; an earlier in-place update may have left a real file there.
    `if [ ! -L /home/cmux/.cmux/bin/cmux-tui ]; then mv -f /home/cmux/.cmux/bin/cmux-tui "$D/home-cmux-tui.orig"; ln -s /opt/cmux/current/bin/cmux-tui /home/cmux/.cmux/bin/cmux-tui; fi`,
    // Old dev profiles and binaries but this one and the last (never the one just made).
    // grep -v exits 1 when nothing else is left: under pipefail that would stop the install here.
    `ls -1dt /opt/cmux/profiles/devloop-* 2>/dev/null | { grep -vxF "$P" || true; } | tail -n +2 | xargs -r sudo -n rm -rf`,
    `ls -1t /opt/cmux/devloop/cmux-tui-* 2>/dev/null | { grep -vxF /opt/cmux/devloop/cmux-tui-${short} || true; } | tail -n +2 | xargs -r sudo -n rm -f`,
    ...restartLines(units),
    `echo "installed ${short}: $(/opt/cmux/current/bin/cmux-tui --version)"`,
  ].join("\n");
}

function restartLines(units: string[]): string[] {
  const out: string[] = [];
  if (units.includes("host")) out.push("sudo -n systemctl restart cmux-host.service");
  if (units.includes("acpmux")) out.push(`XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user restart acpmux.service`);
  return out;
}

export function guestRestoreScript(units: string[]): string {
  return [
    "set -euo pipefail",
    `D=${GUEST_DIR}`,
    `[ -s "$D/original-profile" ] || { echo "nothing to restore: this machine never took a dev binary"; exit 0; }`,
    `sudo -n ln -sfn "$(cat "$D/original-profile")" /opt/cmux/current.devloop && sudo -n mv -Tf /opt/cmux/current.devloop /opt/cmux/current`,
    `if [ -e "$D/home-cmux-tui.orig" ]; then mv -f "$D/home-cmux-tui.orig" /home/cmux/.cmux/bin/cmux-tui; fi`,
    `rm -f "$D/current.bin"`,
    ...restartLines(units),
    `echo "restored $(readlink /opt/cmux/current): $(/opt/cmux/current/bin/cmux-tui --version)"`,
  ].join("\n");
}

/** The build host's side of a push: read {api, bearer, machine, file, mode, guestSha} from stdin and upload. */
async function remoteUpload(): Promise<number> {
  const req = JSON.parse(await Bun.stdin.text());
  const cloud = new Cloud(req.api, "prod");
  cloud.bearer = req.bearer;
  const data = new Uint8Array(readFileSync(path.join(homedir(), req.file)));
  const t0 = now();
  await cloud.exec(req.machine, `rm -rf ${GUEST_DIR}/in && mkdir -p ${GUEST_DIR}/in`);
  const n = await uploadPieces(cloud, req.machine, `${GUEST_DIR}/in`, data);
  console.log(JSON.stringify({ pieces: n, bytes: data.byteLength, seconds: Number(secs(t0)) }));
  return 0;
}

function ssh(host: string, script: string, input?: string, timeoutMs?: number) {
  return sh("ssh", ["-o", "BatchMode=yes", host, script], { input, timeoutMs });
}

async function main(argv = process.argv.slice(2)): Promise<number> {
  if (argv[0] === "__upload") return remoteUpload();
  if (argv.includes("-h") || argv.includes("--help")) {
    console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("*/")[0]);
    return 0;
  }
  const dash = argv.indexOf("--");
  const own = dash >= 0 ? argv.slice(0, dash) : argv;
  const journeyArgs = dash >= 0 ? argv.slice(dash + 1) : [];
  const backend = resolveBackend(argValue("--backend", own) ?? "prod");
  const buildHost = argValue("--build-host", own) ?? process.env.CLOUD_DEVLOOP_BUILD_HOST ?? "";
  if (!buildHost && !own.includes("--no-build")) throw new Error("--build-host HOST or CLOUD_DEVLOOP_BUILD_HOST: an ssh host with cargo, zig under /opt/zig-*, bun and zstd");
  const machineArg = argValue("--machine", own) ?? "cloud-devloop";
  const units = (argValue("--units", own) ?? "host,acpmux").split(",").filter(Boolean);
  const credFile = argValue("--credentials", own);
  const creds = credFile ? readEnvFile(readFileSync(credFile, "utf8")) : {};
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL ?? creds.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD ?? creds.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("no agent test account: CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD or --credentials FILE");
  const times: Array<[string, string]> = [];
  const t0 = now();
  const cloud = new Cloud(backend.api, backend.stack);
  await cloud.signIn(email, password);
  const say = (s: string) => console.log(scrub(s, cloud.secrets));

  // The machine: by id, or by name (made on first use).
  let tm = now();
  const list = await cloud.read("cloud.machine.list", {});
  const rows: any[] = list?.machines ?? list?.items ?? (Array.isArray(list) ? list : []);
  let row = rows.find((m) => m.id === machineArg) ?? rows.find((m) => m.name === machineArg && m.status !== "deleted" && m.status !== "failed");
  if (!row) {
    if (machineArg.startsWith("vm_")) throw new Error(`no machine ${machineArg}`);
    say(`== creating ${machineArg} on ${backend.name}`);
    row = (await cloud.op("cloud.machine.create", { name: machineArg, size: { cpu: 4, memory_mb: 8192, disk_mb: 32768 } })).machine;
  }
  const machine: string = row.id;
  if (row.status === "paused") await cloud.op("cloud.machine.start", { machine });
  for (let i = 0; row.status !== "running" && i < 300; i++) {
    await Bun.sleep(1000);
    row = await cloud.read("cloud.machine.get", { machine });
    if (row.status === "failed") throw new Error(`${machine} failed: ${JSON.stringify(row.error)}`);
  }
  times.push(["machine", secs(tm)]);
  say(`== ${machine} (${row.name}) ${row.status}, image ${row.image?.id}, on ${backend.name}`);

  if (own.includes("--restore")) {
    const r = await cloud.exec(machine, guestRestoreScript(units), 180_000);
    say((r.stdout + r.stderr).trim());
    return r.code;
  }
  if (own.includes("--snapshot")) return snapshot(cloud, machine, say);

  const since = (await cloud.exec(machine, "date -u +%Y-%m-%dT%H:%M:%SZ")).stdout.trim();
  if (!own.includes("--no-build")) {
    // 1. sync
    tm = now();
    const base = must("merge-base", sh("git", ["merge-base", "HEAD", BASE_BRANCH])).trim();
    const files = changedFiles(must("git diff", sh("git", ["diff", "--name-status", "-M", base])), must("git ls-files", sh("git", ["ls-files", "-o", "--exclude-standard"])));
    must("prepare build checkout", ssh(buildHost, remotePrepareScript(base, files.removed), undefined, 600_000));
    const list = files.copy.filter((f) => !f.startsWith("ghostty") && !f.startsWith("ghostty-next/"));
    if (list.length) must("rsync", sh("rsync", ["-a", "--files-from=-", "./", `${buildHost}:${REMOTE_DIR}/`], { input: `${list.join("\n")}\n` }));
    must("record applied", ssh(buildHost, `cat > ~/${REMOTE_DIR}/.git/devloop-applied`, `${list.join("\n")}\n`));
    times.push(["sync", secs(tm)]);
    say(`== synced ${list.length} changed file(s) over ${base.slice(0, 10)} to ${buildHost}`);

    // 2. build
    tm = now();
    const build = ssh(buildHost, [
      "set -euo pipefail",
      `cd ~/${REMOTE_DIR}/cmux-tui`,
      'zig=$(ls -d /opt/zig-* 2>/dev/null | sort -V | tail -1)',
      'export PATH="$zig:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH" ZIG="$zig/zig" CMUX_GHOSTTY_SRC= CMUX_GHOSTTY_VT_ZIG_CPU=baseline CARGO_PROFILE_DEV_DEBUG=false CARGO_PROFILE_DEV_STRIP=true',
      `export CMUX_TUI_BUILD_COMMIT=${base}`,
      "log=~/.cache/cloud-devloop/build.log; mkdir -p ~/.cache/cloud-devloop",
      "if ! cargo build -p cmux-tui --bin cmux-tui --locked --message-format short > $log 2>&1; then grep -E '^(error|[^ ]+:[0-9]+:[0-9]+: error)' $log | head -40; tail -5 $log; exit 1; fi",
      "sha256sum target/debug/cmux-tui | cut -d' ' -f1",
    ].join("\n"), undefined, 3_600_000);
    if (build.code !== 0) {
      say(`FAIL build on ${buildHost}:\n${(build.out + build.err).trim()}`);
      return 1;
    }
    const sha = build.out.trim().split("\n").pop()!;
    times.push(["build", secs(tm)]);
    say(`== built cmux-tui ${sha.slice(0, 12)} in ${times.at(-1)![1]} s`);

    if (!own.includes("--no-push")) {
      // 3. push
      tm = now();
      const state = (await cloud.exec(machine, `mkdir -p ${GUEST_DIR}; cd ${GUEST_DIR}; [ -x zstd ] && echo has-zstd; [ -f current.bin ] && sha256sum current.bin | cut -d' ' -f1; [ -s original-profile ] && cat original-profile; true`)).stdout;
      if (!state.includes("has-zstd")) {
        // zstd for the guest's side of --patch-from: the build host's (same Ubuntu release), once per machine.
        const z = ssh(buildHost, "base64 -w0 /usr/bin/zstd");
        await cloud.exec(machine, `rm -rf ${GUEST_DIR}/zstd.in && mkdir -p ${GUEST_DIR}/zstd.in`);
        await uploadPieces(cloud, machine, `${GUEST_DIR}/zstd.in`, Buffer.from(must("read zstd", z), "base64"));
        must("zstd on the machine", await cloud.exec(machine, `cd ${GUEST_DIR} && cat zstd.in/* > zstd && rm -rf zstd.in && chmod 755 zstd && ./zstd --version`).then((r) => ({ code: r.code, out: r.stdout, err: r.stderr })));
      }
      const guestSha = state.split("\n").find((l) => /^[0-9a-f]{64}$/.test(l)) ?? "";
      if (guestSha === sha) {
        say("== the machine already runs this build");
      } else {
        const pack = ssh(buildHost, [
          "set -euo pipefail",
          `cd ~/${REMOTE_DIR}/cmux-tui`,
          "keep=~/.cache/cloud-devloop; mkdir -p $keep",
          "cp -f target/debug/cmux-tui $keep/new.bin",
          `prev=$keep/${guestSha || "none"}.bin`,
          `if [ -n ${shq(guestSha)} ] && [ -f "$prev" ]; then zstd -q -f -T0 -3 --long=28 --patch-from="$prev" $keep/new.bin -o $keep/push.zst; echo patch; else zstd -q -f -T0 -3 --long=28 $keep/new.bin -o $keep/push.zst; echo full; fi`,
          `mv -f $keep/new.bin $keep/${sha}.bin`,
          // Keep the five newest builds as patch bases.
          "ls -1t $keep/*.bin | tail -n +6 | xargs -r rm -f",
          "stat -c %s $keep/push.zst",
        ].join("\n"));
        const [mode, size] = must("pack", pack).trim().split("\n").slice(-2);
        const up = ssh(buildHost, `cd ~/${REMOTE_DIR} && PATH=$HOME/.bun/bin:$PATH bun scripts/cmux-next/cloud-devloop.ts __upload`,
          JSON.stringify({ api: backend.api, bearer: cloud.bearer, machine, file: ".cache/cloud-devloop/push.zst" }), 600_000);
        const upInfo = must("upload", up).trim().split("\n").pop()!;
        times.push(["push", secs(tm)]);
        say(`== pushed ${mode} ${(Number(size) / 1e6).toFixed(1)} MB: ${upInfo}`);
        // 4. install
        tm = now();
        const inst = await cloud.exec(machine, guestInstallScript(sha, mode as "patch" | "full", units), 240_000);
        if (inst.code !== 0) {
          say(`FAIL install (exit ${inst.code}):\n${(inst.stdout + inst.stderr).trim().split("\n").slice(-20).join("\n")}`);
          return 1;
        }
        times.push(["install+restart", secs(tm)]);
        say(`== ${inst.stdout.trim().split("\n").pop()}`);
      }
    }
  }

  // 5. journey
  let status = 0;
  if (!own.includes("--no-journey")) {
    tm = now();
    const args = ["scripts/cmux-next/cloud-journey.ts", "--backend", backend.name, "--machine", machine, ...(credFile ? ["--credentials", credFile] : []), ...(journeyArgs.includes("--model") ? [] : ["--model", "stub"]), ...(journeyArgs.includes("--skip") ? [] : ["--skip", "sync"]), ...journeyArgs];
    say(`== journey on ${machine}`);
    const r = spawnSync("bun", args, { cwd: root, stdio: ["ignore", "pipe", "inherit"], encoding: "utf8" });
    status = r.status ?? 1;
    const out = r.stdout ?? "";
    process.stdout.write(out);
    times.push(["journey", secs(tm)]);
    const first = out.split("\n").find((l) => l.startsWith("FAIL "));
    if (first && !first.startsWith("FAIL prod:")) {
      say(`\n== first failing step: ${first.slice(5, 400)}`);
      const j = await cloud.exec(machine, `sudo -n journalctl --no-pager -o short-iso --since ${shq(since)} -u cmux-host.service -n 30 2>&1 | tail -30; echo ---- acpmux; journalctl --user --no-pager -o short-iso --since ${shq(since)} -u 'acpmux*' -n 30 2>&1 | tail -30`).catch((e) => ({ stdout: String(e), stderr: "", code: 1 }));
      say(j.stdout.trim());
    }
  }
  say(`\nloop: ${times.map(([k, v]) => `${k} ${v} s`).join(", ")}, total ${secs(t0)} s`);
  return status;
}

/** --snapshot: the dev machine as the next base image (the provider's snapshot of a machine that already works). */
async function snapshot(cloud: Cloud, machine: string, say: (s: string) => void): Promise<number> {
  const t0 = now();
  const v = await cloud.op("cloud.machine.snapshot", { machine }).catch((e: Error) => e);
  if (v instanceof Error) {
    say(`snapshot: ${v.message}`);
    return 1;
  }
  say(`snapshot ${JSON.stringify(v).slice(0, 400)} in ${secs(t0)} s`);
  return 0;
}

export const sha256 = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((c) => process.exit(c), (e) => { console.error(`cloud-devloop: ${(e as Error).message}`); process.exit(1); });
}

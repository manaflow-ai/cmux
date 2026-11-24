#!/usr/bin/env bun
/**
 * Runs one command (cmux-tui/scripts/sync_bench.py) with a store credential of the staging agent test account, for
 * sync-bench scenario e (`cmux link sync push --store`): .github/workflows/sync-store-bench.yml.
 *
 *     bun scripts/cmux-next/sync-store-bench.ts --backend staging --out DIR -- python3 cmux-tui/scripts/sync_bench.py run ...
 *
 * Signs in as the agent test account (CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD) and mints an install token the way the
 * Cloud journey's "install token" step does (cloud-journey.ts: install.register, /v1/auth/challenge, /v1/auth/token),
 * reads the platform origin from GET /v1/client-config (`platform_origin`), writes the token to an owner-only file in
 * a fresh owner-only directory under $RUNNER_TEMP, and runs the command with SYNC_BENCH_STORE=<platform origin> and
 * SYNC_BENCH_STORE_CREDENTIAL=<that file>. Afterwards, pass, fail or SIGTERM, it deletes the file and revokes the
 * install. The install is named as a journey's (`cloud journey jr-<base36 ms>`), so one a killed run leaves live is
 * swept by the next journey (staleJourneyInstalls). Never prints a token; DIR/store.json gets the store's usage
 * before and after (usedBytes, limitBytes, roots) and whether the revoke went through.
 */
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { Api, clientPlatformOrigin, http, passwordSignIn, resolveBackend, scrub, sign, STACK } from "./cloud-journey.ts";

function arg(name: string, argv: string[]): string | undefined {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}

async function usage(platform: string, token: string): Promise<Record<string, unknown>> {
  try {
    const res = await fetch(`${platform}/v1/sync/usage`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(30_000) });
    const body: any = await res.json().catch(() => null);
    if (res.status !== 200) return { status: res.status, code: body?.code ?? null };
    return { status: 200, usedBytes: body?.usedBytes ?? null, limitBytes: body?.limitBytes ?? null, roots: body?.roots ?? null, gc_mode: body?.gc?.mode ?? null };
  } catch (error) {
    return { error: String((error as Error)?.message ?? error).slice(0, 300) };
  }
}

async function main(): Promise<number> {
  const all = process.argv.slice(2);
  const dash = all.indexOf("--");
  const own = dash >= 0 ? all.slice(0, dash) : all;
  const command = dash >= 0 ? all.slice(dash + 1) : [];
  if (!command.length) throw new Error("usage: sync-store-bench.ts --backend staging --out DIR -- COMMAND ...");
  const backend = resolveBackend(arg("--backend", own) ?? "staging");
  if (backend.name === "prod") throw new Error("sync-store-bench runs on staging or dev only, never production");
  const out = arg("--out", own) ?? ".";
  mkdirSync(out, { recursive: true });
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) {
    console.error("sync-store-bench: no agent test account in this environment: CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD are empty");
    return 1;
  }
  const secrets: string[] = [password];
  const say = (line: string) => console.error(scrub(`sync-store-bench: ${line}`, secrets));
  const stack = STACK[backend.stack];
  const api = new Api(backend.api);
  const signIn = async () => {
    const s = await passwordSignIn(stack, email, password);
    secrets.push(s.access, s.refresh);
    api.bearer = s.access;
  };
  await signIn();
  const tag = `jr-${Date.now().toString(36)}`;
  const user = await api.op("user.ensure", {}, `${tag}-ensure`);
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const inst = await api.op("install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: `cloud journey ${tag}`, device_name: "sync store bench", platform: "linux" }, `${tag}-install`);
  const record: Record<string, unknown> = { backend: backend.name, api: backend.api, install: inst.id, tag };
  let dir: string | null = null;
  let revoked = false;
  const cleanup = async () => {
    if (dir) {
      rmSync(dir, { recursive: true, force: true });
      dir = null;
    }
    if (!revoked) {
      revoked = true;
      try {
        // The Stack session may have expired during a long run: a fresh one for the revoke.
        await signIn();
        await api.op("install.revoke", { install: inst.id }, `${tag}-install-revoke`);
        record.install_revoked = true;
      } catch (error) {
        record.install_revoked = false;
        record.revoke_error = scrub(String((error as Error)?.message ?? error).slice(0, 300), secrets);
      }
    }
    writeFileSync(path.join(out, "store.json"), `${JSON.stringify(record, null, 1)}\n`);
  };
  let child: ReturnType<typeof spawn> | null = null;
  const onSignal = (signal: NodeJS.Signals) => {
    child?.kill(signal);
    void cleanup().finally(() => process.exit(signal === "SIGINT" ? 130 : 143));
  };
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  try {
    const userId = inst.user ?? user.id ?? user.user?.id;
    const ch = await http("POST", `${backend.api}/v1/auth/challenge`, { user: userId, install: inst.id }, {});
    if (ch.status !== 200) throw new Error(`challenge HTTP ${ch.status}`);
    const tok = await http("POST", `${backend.api}/v1/auth/token`, { user: userId, install: inst.id, nonce: ch.body.nonce, signature: await sign(pair.privateKey, `${ch.body.message_prefix}${ch.body.nonce}`) }, {});
    if (tok.status !== 200 || typeof tok.body.access_token !== "string") throw new Error(`token HTTP ${tok.status}`);
    const token: string = tok.body.access_token;
    secrets.push(token);
    record.token_expires = tok.body.expires_at ?? tok.body.expires_in ?? null;
    const config = await api.raw("GET", "/v1/client-config", undefined, 30_000);
    if (config.status !== 200) throw new Error(`client-config HTTP ${config.status}`);
    const platform = clientPlatformOrigin(config.body);
    record.platform = platform;
    record.usage_before = await usage(platform, token);
    say(`install ${inst.id} (${tag}), platform ${platform}, store usage before ${JSON.stringify(record.usage_before)}`);
    const base = process.env.RUNNER_TEMP || "/tmp";
    dir = mkdtempSync(path.join(base, "sync-store-cred-"));
    const file = path.join(dir, "credential");
    writeFileSync(file, `${token}\n`, { mode: 0o600, flag: "wx" });
    const started = Date.now();
    const code: number = await new Promise((resolve, reject) => {
      child = spawn(command[0], command.slice(1), { stdio: "inherit", env: { ...process.env, SYNC_BENCH_STORE: platform, SYNC_BENCH_STORE_CREDENTIAL: file, CMUX_DOGFOOD_STACK_EMAIL: "", CMUX_DOGFOOD_STACK_PASSWORD: "" } });
      child.on("error", reject);
      child.on("exit", (c, s) => resolve(c ?? (s ? 128 : 1)));
    });
    record.command_exit = code;
    record.command_s = Math.round((Date.now() - started) / 1000);
    record.usage_after = await usage(platform, token);
    say(`command exit ${code} after ${record.command_s}s; store usage after ${JSON.stringify(record.usage_after)}`);
    return code;
  } finally {
    await cleanup();
    say(`install ${inst.id} revoked: ${record.install_revoked}${record.revoke_error ? ` (${record.revoke_error})` : ""}`);
  }
}

main().then((code) => process.exit(code), (error) => {
  console.error(`sync-store-bench: ${String((error as Error)?.message ?? error).slice(0, 500)}`);
  process.exit(1);
});

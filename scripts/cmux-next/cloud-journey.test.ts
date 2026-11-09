import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claudeLoginPrograms, loginBearer, loginPrograms, stubCodexAuth, validLogin, INSTALLER_SWIFT, JOURNEY_STUB_SCRIPT, MODEL_STUB_PY, newReds, probeRow, readEnvFile, resolveBackend, scrub, summaryMarkdown, swiftRawString } from "./cloud-journey";
import { oidcSignIn, waitPreflight, CODEX_STUB_CONFIG, PREFLIGHT_PROBE } from "./cloud-journey";
import { deleteJourneyMachines, journeyMachineEligible, leakProof, machineLine, parseDeleteEntries, provenLeak, type MachineScope } from "./cloud-journey";
import { canonicalKey, carrierDial, carrierTicketProblem, dialDetail, dialPhases, guestTimeline, JOURNAL_FIELD, hopSpans, hopTimes, machineIds, newMachineIds, opRetryable, IDLE_JOURNEY_MS, listAllMachines, staleJourneyMachines, STALE_JOURNEY_MS } from "./cloud-journey";

describe("cloud journey", () => {
  test("--sign-in oidc trades the job's OIDC token for the API's session and keeps both out of the output", async () => {
    const calls: Array<{ method: string; url: string; auth: string }> = [];
    const fake = async (method: string, url: string, _body: unknown, headers: Record<string, string>) => {
      calls.push({ method, url, auth: headers.authorization ?? "" });
      if (url.startsWith("https://gh.example/token")) return { status: 200, body: { value: "gh-oidc-jwt-value" } };
      return { status: 200, body: { access_token: "stack-access-value", user: "user_x", session_expires_at: "2026-11-04T18:00:00.000Z" } };
    };
    const secrets: string[] = [];
    const s = await oidcSignIn("https://cloud-api.cmux.dev", { ACTIONS_ID_TOKEN_REQUEST_URL: "https://gh.example/token?x=1", ACTIONS_ID_TOKEN_REQUEST_TOKEN: "request-bearer" }, secrets, fake as never);
    expect(s).toEqual({ token: "stack-access-value", user: "user_x", expiresAt: "2026-11-04T18:00:00.000Z" });
    expect(calls[0]).toEqual({ method: "GET", url: "https://gh.example/token?x=1&audience=https%3A%2F%2Fcloud-api.cmux.dev", auth: "bearer request-bearer" });
    expect(calls[1]).toEqual({ method: "POST", url: "https://cloud-api.cmux.dev/v1/auth/github-actions", auth: "Bearer gh-oidc-jwt-value" });
    expect(secrets).toEqual(["request-bearer", "gh-oidc-jwt-value", "stack-access-value"]);
    // What the journey renders goes through scrub with that list: none of the three survives.
    const rendered = scrub(`GET bearer request-bearer -> gh-oidc-jwt-value; session stack-access-value`, secrets);
    for (const v of secrets) expect(rendered).not.toContain(v);
    await expect(oidcSignIn("https://cloud-api.cmux.dev", {}, [], fake as never)).rejects.toThrow("id-token: write");
    const refused = async () => ({ status: 401, body: { error: "this token is not trusted to sign in", value: "gh-oidc-jwt-value" } });
    await expect(oidcSignIn("https://cloud-api.cmux.dev", { ACTIONS_ID_TOKEN_REQUEST_URL: "https://gh.example/t", ACTIONS_ID_TOKEN_REQUEST_TOKEN: "rb" }, [], refused as never)).rejects.toThrow("GitHub OIDC token HTTP 401");
  });
  test("backend names map to the cmux API Worker of each environment", () => {
    expect(resolveBackend("staging").api).toBe("https://cloud-api-staging.cmux.dev");
    expect(resolveBackend("prod")).toEqual({ name: "prod", api: "https://cloud-api.cmux.dev", stack: "prod" });
    expect(resolveBackend("preview-35100").api).toBe("https://cmux-api-preview-35100.debussy.workers.dev");
    expect(resolveBackend("preview-leo1").stack).toBe("dev");
    expect(resolveBackend("local", undefined, undefined, 9000).api).toBe("http://127.0.0.1:9000");
    expect(resolveBackend("custom", "https://x.example/", "prod")).toEqual({ name: "custom", api: "https://x.example", stack: "prod" });
    expect(() => resolveBackend("classic")).toThrow();
    expect(() => resolveBackend("preview-A_B")).toThrow();
  });
  test("secrets never reach the output", () => {
    const out = scrub("token eyJabcdefghijk.payload Bearer abc cmuxvm_sk_0123456789 pw hunter22", ["hunter22"]);
    expect(out).not.toContain("eyJabcdefghijk");
    expect(out).not.toContain("cmuxvm_sk_0123456789");
    expect(out).not.toContain("hunter22");
    expect(out).not.toMatch(/Bearer abc/);
  });
  test("env files and the summary table", () => {
    expect(readEnvFile("export A='1'\nB=\"two\"\n# c\n")).toEqual({ A: "1", B: "two" });
    const md = summaryMarkdown(resolveBackend("staging"), [
      { step: "health", status: "pass", ms: 10, detail: "a|b" },
      { step: "reply", status: "fail", ms: 5, detail: "x" },
    ]);
    expect(md.startsWith("FAIL")).toBe(true);
    expect(md).toContain("| **FAIL** | reply | 5 | x |");
    expect(md).toContain("a\\|b");
  });

  test("a carrier dial's detail keeps its phases in the summary, up to 1000 characters", () => {
    const phases = Array.from({ length: 8 }, (_, i) => `reconnect relay: ticket 300, relay ${15_000 + i}, parked 0, handshake 0, mux 0 ms, lanes 0, ${15_300 + i} ms`);
    const detail = dialDetail({ connectMs: 640, replyMs: 900, retries: 5, failed: [], phases, reply: "{}" });
    expect(detail.length).toBeGreaterThan(600);
    const md = summaryMarkdown(resolveBackend("staging"), [{ step: "connect (carrier dial)", status: "pass", ms: 900, detail }]);
    expect(md).toContain(phases[7]);
  });

  test("newReds: only steps the deploy turned red", () => {
    const st = (step: string, status: "pass" | "fail" | "skip") => ({ step, status, ms: 1, detail: "" });
    const before = [st("health", "pass"), st("create machine", "pass"), st("running (status)", "fail")];
    const after = [st("health", "fail"), st("create machine", "pass"), st("running (status)", "fail")];
    // running (status) was already red before the deploy (a known bug): not a rollback.
    expect(newReds(before, after).map((s) => s.step)).toEqual(["health"]);
    expect(newReds(before, [st("health", "pass"), st("running (status)", "fail")])).toEqual([]);
    // No baseline: every failed step counts.
    expect(newReds(null, after).map((s) => s.step)).toEqual(["health", "running (status)"]);
  });
  test("the login copy runs the Mac installer's own programs", () => {
    expect(swiftRawString('  static let x = #"""\n      a\n        b\n      """#', "x")).toBe("a\n  b");
    const programs = claudeLoginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"));
    expect(programs.preflight.startsWith("set -eu\n")).toBe(true);
    expect(programs.preflight).toContain("/etc/cmux/vm-kind");
    const install = programs.install("/home/cmux/.cmux/credential-transfer/A.json");
    expect(install).toContain("python3 - 'claude' '/home/cmux/.cmux/credential-transfer/A.json' owner <<'CMUX_CREDENTIAL_INSTALL'\nimport json, os");
    expect(install).toContain("env['CLAUDE_CODE_OAUTH_TOKEN'] = value");
    expect(install.endsWith("\nCMUX_CREDENTIAL_INSTALL")).toBe(true);
  });
  test("a run is one probe row", () => {
    const at = new Date("2026-11-04T11:00:00.123Z");
    const ok = probeRow("cloud-chat-replies-production", [
      { step: "send chat", status: "pass", ms: 800, detail: "" },
      { step: "reply", status: "pass", ms: 4200, detail: "Earth." },
    ], "https://x/runs/1", at);
    expect(ok).toEqual({ probe: "cloud-chat-replies-production", at: "2026-11-04T11:00:00Z", runner: "github-actions", run: "https://x/runs/1", outcome: "ok", ms: 5000 });
    const bad = probeRow("p", [{ step: "create machine", status: "fail", ms: 5, detail: "HTTP 503" }], undefined, at);
    expect(bad).toMatchObject({ outcome: "fail", error: "create machine: HTTP 503" });
  });
  test("the journey's stub script is valid for the shared model stub and its reply repeats the tool output", () => {
    expect(readFileSync(MODEL_STUB_PY, "utf8")).toContain("--ready-file");
    expect(JOURNEY_STUB_SCRIPT.steps[0].shell).not.toContain("{{nonce}}-tool");
    expect(JOURNEY_STUB_SCRIPT.steps[1].text).toContain("{{result.0}}");
  });
  test("a team machine gets the DEV creator allowance, as a nightly build copies", () => {
    const team = claudeLoginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), true);
    expect(team.preflight).toContain("owner|team");
    expect(team.install("/p.json")).toContain("'/p.json' owner,team <<");
    expect(claudeLoginPrograms(readFileSync(INSTALLER_SWIFT, "utf8")).install("/p.json")).toContain("'/p.json' owner <<");
  });
  test("Codex: the made-up sign-in passes the app's validation and the installer gets the codex provider", () => {
    const auth = stubCodexAuth("ab".repeat(16), new Date("2026-11-04T00:00:00Z"));
    expect(validLogin("codex", auth)).toBe(true);
    expect(validLogin("codex", JSON.stringify({ OPENAI_API_KEY: "sk-x", tokens: {} }))).toBe(false);
    expect(validLogin("claude", auth)).toBe(false);
    expect(loginBearer("codex", auth)).toBe(JSON.parse(auth).tokens.access_token);
    expect(loginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), "codex").install("/p.json")).toContain("python3 - 'codex' '/p.json' owner <<");
  });
  test("Codex: the stub config pins the stub's model and keeps the made-up sign-in off chatgpt.com", () => {
    const dir = mkdtempSync(join(tmpdir(), "journey-codex-config-"));
    // Runs CODEX_STUB_CONFIG on a config.toml, then reads it back with Python's own TOML parser.
    const point = (before: string | null) => {
      const file = join(dir, "config.toml");
      rmSync(file, { force: true });
      if (before !== null) writeFileSync(file, before);
      const run = (args: string[], input: string) => spawnSync("python3", args, { input, encoding: "utf8" });
      const r = run(["-", "4711", file], CODEX_STUB_CONFIG);
      expect(r.stderr).toBe("");
      expect(r.stdout.trim()).toBe("stub-ready");
      const read = run(["-c", "import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], 'rb'))))", file], "");
      expect(read.stderr).toBe("");
      return JSON.parse(read.stdout);
    };
    try {
      const want = (c: any) => {
        expect(c.model).toBe("stub-model");
        expect(c.model_provider).toBe("journeystub");
        expect(c.chatgpt_base_url).toBe("http://127.0.0.1:4711/backend-api/");
        expect(c.model_providers.journeystub).toEqual({ name: "journey stub", base_url: "http://127.0.0.1:4711/v1", wire_api: "responses", requires_openai_auth: true });
        expect(c.features).toMatchObject({ apps: false, plugins: false, remote_plugin: false });
        expect(c.analytics.enabled).toBe(false);
      };
      want(point(null));
      // The image's own settings stay; the keys the stub needs replace theirs, in the tables they already have.
      const image = 'model = "gpt-6.1-sol"\napproval_policy = "never"\n\n[features]\nplugins = true\nshell_snapshot = true\n\n[analytics]\nenabled = true\n\n[projects."/home/cmux"]\ntrust_level = "trusted"\n';
      const c = point(image);
      want(c);
      expect(c.approval_policy).toBe("never");
      expect(c.features.shell_snapshot).toBe(true);
      expect(c.projects["/home/cmux"].trust_level).toBe("trusted");
      // An active profile's model and model_provider would win over the root ones: no profile stays active.
      const profiled = point('profile = "work"\n\n[profiles.work]\nmodel = "gpt-6.1-sol"\nmodel_provider = "openai"\n');
      want(profiled);
      expect(profiled.profile).toBeUndefined();
      expect(profiled.profiles.work.model).toBe("gpt-6.1-sol");
      // A second run (a resumed machine) rewrites the provider table instead of adding one TOML refuses.
      want(point(readFileSync(join(dir, "config.toml"), "utf8")));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("cloud journey: login preflight", () => {
  test("the login preflight waits for the guest's bind, then names the failing check", async () => {
    const noPause = async () => {};
    let calls = 0;
    const late = async (command: string) => ({ code: command === "pre" && ++calls >= 3 ? 0 : 1, stdout: "", stderr: "" });
    expect(await waitPreflight(late, "pre", "owner", 90_000, 0, noPause)).toMatchObject({ tries: 3 });
    const never = async (command: string) => ({ code: command === PREFLIGHT_PROBE ? 0 : 1, stdout: command === PREFLIGHT_PROBE ? "vm-kind= agent-auth.sh=yes user=cmux\n" : "", stderr: "" });
    await expect(waitPreflight(never, "pre", "owner", 0, 0, noPause)).rejects.toThrow(/preflight exit 1 after 1 tries .*not an owner machine with the image's launchers \(vm-kind= agent-auth.sh=yes user=cmux\)/);
  });
});

describe("cloud journey: app cli", () => {
  test("app cli: machines new since a create are listed, never picked", () => {
    expect(machineIds([{ id: "vm_a" }, { machine_id: "vm_b" }, { id: "vm_c", status: "deleted" }, {}])).toEqual(["vm_a", "vm_b"]);
    expect(newMachineIds(["vm_a"], ["vm_a", "vm_b", "vm_b"])).toEqual(["vm_b"]);
    expect(newMachineIds(["vm_a"], ["vm_a"])).toEqual([]);
  });
});

describe("cloud journey: leaked machine sweep", () => {
  const now = Date.UTC(2026, 10, 9, 12, 0, 0);
  const tagAt = (ms: number) => `jr-${ms.toString(36)}`;
  const ids = (rows: any[], at = now) => staleJourneyMachines(rows, at).map((m) => m.id);

  test("takes only an auto-named journey machine (and gateway) older than any journey run, in any state", () => {
    const old = tagAt(now - STALE_JOURNEY_MS - 60_000);
    const young = tagAt(now - STALE_JOURNEY_MS + 60_000);
    expect(ids([
      { id: "vm_running", name: `cloud journey auto ${old}`, status: "running" },
      { id: "vm_paused_gw", name: `cloud journey auto ${old} gateway`, status: "paused" },
      { id: "vm_young", name: `cloud journey auto ${young}`, status: "paused" },
      { id: "vm_gone", name: `cloud journey auto ${old}`, status: "deleted" },
      { id: "vm_deleting", name: `cloud journey auto ${old}`, status: "deleting" },
    ])).toEqual(["vm_running", "vm_paused_gw"]);
    // Just inside the bound is a concurrent run's machine; just past it is leaked.
    const edge = { id: "vm_edge", name: `cloud journey auto ${tagAt(now - STALE_JOURNEY_MS)}`, status: "paused" };
    expect(ids([edge])).toEqual([]);
    expect(ids([edge], now + 1)).toEqual(["vm_edge"]);
  });

  test("never a machine with recent activity, however old", () => {
    const old = tagAt(now - 2 * STALE_JOURNEY_MS);
    expect(ids([
      { id: "vm_active", name: `cloud journey auto ${old}`, status: "running", last_active_at: now - 5 * 60_000 },
      { id: "vm_edge", name: `cloud journey auto ${old}`, status: "running", last_active_at: now - IDLE_JOURNEY_MS },
      { id: "vm_idle", name: `cloud journey auto ${old}`, status: "running", last_active_at: now - IDLE_JOURNEY_MS - 1 },
    ])).toEqual(["vm_idle"]);
  });

  test("the age bound outlasts every workflow job that runs a journey, twice over", () => {
    const dir = join(import.meta.dir, "../../.github/workflows");
    const seen: string[] = [];
    for (const f of readdirSync(dir).filter((n) => /\.ya?ml$/.test(n))) {
      const text = readFileSync(join(dir, f), "utf8");
      if (!/cloud-journey(\.ts|-ci\.sh)/.test(text)) continue;
      seen.push(f);
      // Every timeout in such a file, a superset of the journey jobs' own.
      for (const m of text.matchAll(/timeout-minutes:\s*(\d+)/g)) {
        expect({ f, fits: Number(m[1]) * 60_000 * 2 <= STALE_JOURNEY_MS }).toEqual({ f, fits: true });
      }
    }
    expect(seen).toContain("cmux-vm.yml");
  });

  test("never a --keep run's plain name, another name or a tag that is not a time", () => {
    const old = tagAt(now - 48 * 3600_000);
    expect(ids([
      { id: "vm_kept", name: `cloud journey ${old}`, status: "paused" },
      { id: "vm_kept_gw", name: `cloud journey ${old} gateway`, status: "failed" },
      { id: "vm_dev", name: "dev machine", status: "paused" },
      { id: "vm_named", name: `my cloud journey auto ${old}`, status: "paused" },
      { id: "vm_bad", name: "cloud journey auto jr-!!", status: "paused" },
      { id: "vm_tiny", name: "cloud journey auto jr-zz", status: "paused" },
      { id: "vm_future", name: `cloud journey auto ${tagAt(now + 3600_000)}`, status: "paused" },
      null,
    ])).toEqual([]);
    const [m] = staleJourneyMachines([{ id: "vm_x", name: `cloud journey auto ${old}`, status: "paused", created_at: now - 48 * 3600_000 }], now);
    expect(m).toEqual({ id: "vm_x", name: `cloud journey auto ${old}`, status: "paused", created: new Date(now - 48 * 3600_000).toISOString() });
  });

  test("reads every page of the machine list", async () => {
    const pages: Record<string, any> = {
      "": { machines: [{ id: "a" }], next_cursor: "c1" },
      c1: { machines: [{ id: "b" }], next_cursor: "c2" },
      c2: { machines: [{ id: "c" }], next_cursor: null },
    };
    const asked: any[] = [];
    const rows = await listAllMachines(async (p) => { asked.push(p); return pages[String(p.cursor ?? "")]; });
    expect(rows.map((r) => r.id)).toEqual(["a", "b", "c"]);
    expect(asked).toEqual([{ limit: 100 }, { limit: 100, cursor: "c1" }, { limit: 100, cursor: "c2" }]);
    // A list that never ends is an error (the sweep then deletes nothing), not a partial sweep.
    await expect(listAllMachines(async () => ({ machines: [], next_cursor: "again" }), 3)).rejects.toThrow("more than 3 pages");
  });
});

describe("carrier dial step", () => {
  // A stand-in for `cmux carrier dial`: its status and route lines on stderr, then the daemon's answer to each line.
  const fakeCmux = (body: string) => {
    const dir = mkdtempSync(join(tmpdir(), "journey-carrier-"));
    const bin = join(dir, "cmux");
    writeFileSync(bin, `#!/bin/bash\nprintf '%s\\n' "$*" > "${dir}/args"\nprintf '%s\\n' "$CMUX_CLOUD_API_URL $CMUX_CLOUD_ACCESS_TOKEN \${CMUX_CLOUD_TEAM:--}" > "${dir}/env"\n${body}\n`, { mode: 0o755 });
    return { dir, bin };
  };
  const api = { origin: "https://api.example", bearer: "session-value", team: "team_0123456789abcdef0123" };

  test("passes on the carrier route and the daemon's answer, with the dial's own connect time", async () => {
    const { dir, bin } = fakeCmux(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=812' >&2
read -r line; echo '{"event":"pushed","conn":0}'; echo '{"id":1,"ok":true,"data":{"app":"cmux-tui","protocol":12}}'; cat >/dev/null`);
    process.env.CMUX_CLOUD_TEAM = "team_inherited000000000000";
    const d = await carrierDial(bin, { ...api, team: undefined }, "vm_abcdefghij0123456789", 2_000).finally(() => delete process.env.CMUX_CLOUD_TEAM);
    expect(d.connectMs).toBe(812);
    expect(d.reply).toBe('{"id":1,"ok":true,"data":{"app":"cmux-tui","protocol":12}}');
    expect(d.replyMs).toBeGreaterThanOrEqual(0);
    // No team of its own: none is passed, and the inherited CMUX_CLOUD_TEAM is dropped.
    expect(readFileSync(join(dir, "args"), "utf8").trim()).toBe("carrier dial --machine vm_abcdefghij0123456789 --deadline-ms 2000");
    expect(readFileSync(join(dir, "env"), "utf8").trim()).toBe("https://api.example session-value -");
    rmSync(dir, { recursive: true, force: true });
  });

  test("a failed attempt the dial retries is counted, and the ok attempt's time is the connect time", async () => {
    const { dir, bin } = fakeCmux(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=relay ms=3001' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=640' >&2
read -r line; echo '{"id":1,"ok":true,"data":{"app":"cmux-tui"}}'; cat >/dev/null`);
    const d = await carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000);
    expect({ connectMs: d.connectMs, retries: d.retries, failed: d.failed }).toEqual({ connectMs: 640, retries: 1, failed: ["relay 3001 ms"] });
    rmSync(dir, { recursive: true, force: true });
  });

  test("a dial that gives up names every failed attempt, from the route lines after its status line", async () => {
    const { dir, bin } = fakeCmux(`echo '{"ok":false,"error_code":"relay"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=relay ms=15003' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=reconnect outcome=handshake ms=902' >&2
exit 1`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("(failed attempts: relay 15003 ms, handshake 902 ms)");
    rmSync(dir, { recursive: true, force: true });
  });

  test("a dial cut off before an ok attempt names the failed ones", async () => {
    const { dir, bin } = fakeCmux(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=relay ms=3001' >&2
exit 1`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("ended with no ok route line (failed attempts: relay 3001 ms)");
    rmSync(dir, { recursive: true, force: true });
  });

  test("each attempt's phases come from the dial's own connect log, and the state dir goes with the dial", async () => {
    const { dir, bin } = fakeCmux(`mkdir -p "$CMUX_TUI_STATE_DIR/carrier"; echo "$CMUX_TUI_STATE_DIR" > "${"$"}{0%/*}/state"
log="$CMUX_TUI_STATE_DIR/carrier/connect.log"
echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=relay ms=3001' >&2
echo 'carrier.phases machine=vm_x phase=connect carrier=relay:0 outcome=relay ticket_ms=410 relay_ms=2591 parked_ms=0 handshake_ms=0 mux_ms=0 lanes=0 ms=3001' >> "$log"
echo 'cloud.connect route=carrier machine=vm_x phase=reconnect outcome=ok ms=640' >&2
echo 'carrier.phases machine=vm_x phase=reconnect carrier=relay:0 outcome=ok ticket_ms=300 relay_ms=40 parked_ms=120 handshake_ms=150 mux_ms=30 lanes=3 ms=640' >> "$log"
read -r line; echo '{"id":1,"ok":true,"data":{"app":"cmux-tui"}}'; cat >/dev/null`);
    const d = await carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000);
    expect(d.phases).toEqual(["connect relay: ticket 410, relay 2591, parked 0, handshake 0, mux 0 ms, lanes 0, 3001 ms",
      "reconnect ok: ticket 300, relay 40, parked 120, handshake 150, mux 30 ms, lanes 3, 640 ms"]);
    expect(dialDetail(d)).toContain("1 retried attempts (relay 3001 ms); phases: connect relay: ticket 410");
    expect(dialDetail(d)).not.toContain("vm_x");
    expect(existsSync(readFileSync(join(dir, "state"), "utf8").trim())).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });

  test("a dial that gives up shows each attempt's phases too", async () => {
    const { dir, bin } = fakeCmux(`mkdir -p "$CMUX_TUI_STATE_DIR/carrier"
echo 'carrier.phases machine=vm_x phase=connect carrier=relay:0 outcome=parked_timeout ticket_ms=200 relay_ms=30 parked_ms=1700 handshake_ms=0 mux_ms=0 lanes=1 ms=1930' >> "$CMUX_TUI_STATE_DIR/carrier/connect.log"
echo '{"ok":false,"error_code":"parked_timeout"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=parked_timeout ms=1930' >&2
exit 1`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow(
      "(failed attempts: parked_timeout 1930 ms) (phases: connect parked_timeout: ticket 200, relay 30, parked 1700, handshake 0, mux 0 ms, lanes 1, 1930 ms)");
    rmSync(dir, { recursive: true, force: true });
  });

  test("a refused identify shows the attempts' phases too", async () => {
    const { dir, bin } = fakeCmux(`mkdir -p "$CMUX_TUI_STATE_DIR/carrier"
echo 'carrier.phases machine=vm_x phase=connect carrier=relay:0 outcome=ok ticket_ms=200 relay_ms=30 parked_ms=90 handshake_ms=110 mux_ms=20 lanes=3 ms=450' >> "$CMUX_TUI_STATE_DIR/carrier/connect.log"
echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=450' >&2
read -r line; echo '{"id":1,"ok":false,"error":"denied"}'; cat >/dev/null`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow(
      /identify answered .* \(phases: connect ok: ticket 200, relay 30, parked 90, handshake 110, mux 20 ms, lanes 3, 450 ms\)/);
    rmSync(dir, { recursive: true, force: true });
  });

  test("dialPhases keeps a field it does not know, and nothing but phases lines", () => {
    expect(dialPhases("noise\ncarrier.phases machine=vm_x phase=connect outcome=relay ticket_ms=1 ms=2 detail=4003\n")).toEqual(
      ["connect relay: ticket 1 ms, detail 4003, 2 ms"]);
  });

  test("a route line before the status line is out of contract", async () => {
    const { dir, bin } = fakeCmux(`echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=5' >&2
echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
read -r line; echo '{"id":1,"ok":true,"data":{"app":"cmux-tui"}}'; cat >/dev/null`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("a route line before the status line");
    rmSync(dir, { recursive: true, force: true });
  });

  test("names the step the dial did not get past", async () => {
    const { dir, bin } = fakeCmux(`echo '{"ok":false,"error_code":"parked_timeout"}' >&2; exit 1`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("parked_timeout");
    rmSync(dir, { recursive: true, force: true });
  });

  test("refuses another route, and a stream that ends with no answer", async () => {
    const other = fakeCmux(`echo '{"ok":true,"path_state":"relay","route":"link"}' >&2; cat >/dev/null`);
    await expect(carrierDial(other.bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("route link, not carrier");
    const silent = fakeCmux(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=5' >&2
exit 0`);
    await expect(carrierDial(silent.bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("before the daemon answered");
    for (const d of [other.dir, silent.dir]) rmSync(d, { recursive: true, force: true });
  });

  test("an identify refused or answered with no identity fails, and a dial that exits before the write fails the step", async () => {
    const connected = `echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=5' >&2`;
    const refused = fakeCmux(`${connected}\nread -r line; echo '{"id":1,"ok":false,"error":"denied"}'; cat >/dev/null`);
    await expect(carrierDial(refused.bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("identify answered");
    const bare = fakeCmux(`${connected}\nread -r line; echo '{"id":1,"ok":true,"data":{}}'; cat >/dev/null`);
    await expect(carrierDial(bare.bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("identify answered");
    const gone = fakeCmux(`${connected}\nexec 0<&-; exit 0`);
    await expect(carrierDial(gone.bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("carrier dial");
    await expect(carrierDial("/nonexistent/cmux", api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("carrier dial: ");
    for (const d of [refused.dir, bare.dir, gone.dir]) rmSync(d, { recursive: true, force: true });
  });

  test("the gateway hop cost drops the warm-up, needs every call answered 200, and reports ms percentiles", () => {
    const lines = (rows: string[]) => ["noise", ...rows.map((r) => `hop-t ${r}`)].join("\n");
    const out = lines(["200 9.000 9.000 0", ...Array.from({ length: 10 }, (_, i) => `200 ${((i + 1) / 100).toFixed(3)} ${((i + 1) / 10).toFixed(3)} 0`)]);
    expect(hopTimes(out, 10)).toEqual({ ttfb_p50: 50, ttfb_p90: 90, total_p50: 500, total_p90: 900 });
    expect(() => hopTimes(lines(["200 0.1 0.1 0", "200 0.1 0.1 0"]), 2)).toThrow("1 of 2 timed calls");
    expect(() => hopTimes(lines(["200 0.1 0.1 0", "502 0.1 0.1 0"]), 1)).toThrow("did not answer 200 whole (502 exit 0)");
    expect(() => hopTimes(lines(["200 0.1 0.1 0", "200 0.1 0.1 18"]), 1)).toThrow("(200 exit 18)");
  });

  test("the hop split reads each call's Server-Timing after its timing line and derives the object's own hop", () => {
    const call = (ttfb: number, st: string | null) => [`hop-t 200 ${(ttfb / 1000).toFixed(3)} 0.300 0`, ...(st ? [`hop-s ${st}`] : [])];
    const st = (auth: number, wd: number, wait: number, gw: number) => `auth;dur=${auth}, worker-do;dur=${wd}, do-wait;dur=${wait}, do-gateway;dur=${gw}`;
    const out = [
      ...call(900, st(90, 900, 90, 90)), // warm-up, dropped
      ...call(230, st(5, 200, 2, 150)),
      ...call(240, st(7, 210, 4, 160)),
      ...call(250, st(9, 220, 6, 170)),
    ].join("\n");
    expect(hopSpans(out)).toEqual({ calls: 3, untimed: 0, auth: 7, "worker-do": 210, "do-wait": 4, "do-gateway": 160, object_hop: 46, edge: 23 });
    // A counted call without the spans is reported, not hidden in a smaller sample.
    expect(hopSpans([out, ...call(260, null), ...call(270, "auth;dur=1")].join("\n"))).toMatchObject({ calls: 3, untimed: 2 });
    expect(hopSpans([...call(200, null), ...call(200, null)].join("\n"))).toBeNull();
    expect(hopSpans([...call(200, null), ...call(200, "auth;dur=1, worker-do;dur=2")].join("\n"))).toBeNull();
  });
});

describe("opRetryable", () => {
  test("retries only a cut-off provider call the API marks retryable", () => {
    expect(opRetryable({ ok: false, error: { code: "mutation.indeterminate", message: "the provider call was cut off; retry with the same key", retryable: true } })).toBe(true);
    expect(opRetryable({ ok: false, error: { code: "mutation.indeterminate", retryable: false } })).toBe(false);
    expect(opRetryable({ ok: false, error: { code: "cloud.provider.unavailable", retryable: true } })).toBe(false);
    expect(opRetryable({ ok: true, value: {} })).toBe(false);
    expect(opRetryable("vm_unavailable")).toBe(false);
  });
});

describe("guest carrier timeline", () => {
  test("each guest time is ms after create's answer on the guest's boot clock, whatever its wall clock reads", () => {
    // The guest's wall clock runs 1000 ms ahead: guest_now 21_500 at uptime 10_500, the exec's midpoint 20_500, so
    // the guest booted at 10_000 here, the moment create answered.
    const out = ["guest_now 21500 10500", "clock 11200 11000", "wall bound.json 12500", "mono session_host_start 6000",
      "journal 5900 cmux-host[7]: cmux-host: session host 40 exited after 900 ms", "noise line"].join("\n");
    expect(guestTimeline(out, 10_000, 20_000, 21_000)).toBe(
      'after create\'s answer (±500 ms): guest boot +0 ms; bound.json +1500 ms; session_host_start +6000 ms; '
      + 'journal "cmux-host[7]: cmux-host: session host 40 exited after 900 ms" +5900 ms');
  });

  test("a file written before the guest's wall clock stepped is read in the clock it was written in", () => {
    // Booted with its wall clock 96 s behind (resumed from a snapshot), synced at 30 s after boot. bound.json was
    // written 4319 ms after boot under the old clock, carrier.json 40 s after boot under the new one.
    const out = ["guest_now 200100 100100", "clock 4500 4000", "clock 130000 100000", "wall bound.json 8319",
      "wall carrier.json 140000"].join("\n");
    expect(guestTimeline(out, 100_000, 200_000, 200_200)).toBe(
      "after create's answer (±100 ms; the guest's wall clock stepped +96000 ms after boot): guest boot +0 ms; "
      + "bound.json +4319 ms; carrier.json +40000 ms");
  });

  test("a machine bound before create answered reads as a claimed spare", () => {
    // Booted 8.8 days ago from its snapshot base and bound 231.5 s before create answered.
    const out = ["guest_now 1000000000 760954248", "wall bound.json 999768500"].join("\n");
    expect(guestTimeline(out, 1_000_000_000, 999_999_900, 1_000_000_100)).toBe(
      "after create's answer (±100 ms; a claimed spare: bound 231500 ms before create answered): guest boot -760954248 ms; bound.json -231500 ms");
  });

  test("a cold machine that binds while create's answer is on its way back is not a spare", () => {
    // Create was sent at 997_000 and answered at 1_000_000; the guest bound at 999_000, between the two.
    const out = ["guest_now 1000000000 60000", "wall bound.json 999999000"].join("\n");
    expect(guestTimeline(out, 1_000_000_000, 999_999_900, 1_000_000_100, 999_997_000)).toBe(
      "after create's answer (±100 ms): guest boot -60000 ms; bound.json -1000 ms");
  });

  test("says so when the guest showed nothing", () => {
    expect(guestTimeline("", 10_000, 20_000, 20_100)).toBe("after create's answer (±50 ms): no guest clock read");
  });

  test("the journal field reader reads a message past its escaped quotes", () => {
    const line = '{"__MONOTONIC_TIMESTAMP":"5900000","MESSAGE":"carrier \\"relay:0\\" registered","X":"y"}';
    const r = spawnSync("awk", [`${JOURNAL_FIELD} { print field("MESSAGE") "|" field("__MONOTONIC_TIMESTAMP") "|" field("missing") }`], { input: `${line}\n`, encoding: "utf8" });
    expect(r.stdout).toBe('carrier "relay:0" registered|5900000|\n');
  });
});


describe("cloud journey: carrier ticket without a cmux binary", () => {
  const key = Buffer.alloc(32, 7).toString("base64url");
  const whole = { relay: "relay+do://cmux-remote-relay-production.debussy.workers.dev", slot: "s_1-x", ticket: "t.t", grant: "g.g.g", daemon_key: key, expires_at: 2_000 };
  const answer = (patch: Record<string, unknown>) => ({ ok: true, value: { ...whole, ...patch } });
  test("an answer the dial takes passes", () => {
    expect(carrierTicketProblem(200, answer({}), 1_000)).toBeNull();
  });
  test("a refusal names its status", () => {
    expect(carrierTicketProblem(503, { ok: false, error: { code: "owner.unreachable" } }, 1_000)).toContain("HTTP 503");
  });
  test("the dial's relay rule: a bare relay+do:// with a host", () => {
    for (const relay of ["relay+do://", "wss://x", "relay+do://h/path", "relay+do://h?q=1", "relay+do://u@h", undefined])
      expect(carrierTicketProblem(200, answer({ relay }), 1_000)).toMatch(/relay/);
    expect(carrierTicketProblem(200, answer({ relay: "relay+do://h/" }), 1_000)).toBeNull();
  });
  test("the dial's slot, ticket and grant rules", () => {
    for (const slot of ["", " ", "a b", "x".repeat(129), 3]) expect(carrierTicketProblem(200, answer({ slot }), 1_000)).toContain("slot");
    for (const ticket of ["", "a b", undefined]) expect(carrierTicketProblem(200, answer({ ticket }), 1_000)).toContain("ticket");
    for (const grant of ["", " ", undefined]) expect(carrierTicketProblem(200, answer({ grant }), 1_000)).toContain("grant");
    expect(carrierTicketProblem(200, answer({}), 3_000)).toContain("not live");
  });
  test("the daemon key the dial pins is canonical 32-byte base64url", () => {
    expect(canonicalKey(key)).toBe(true);
    const lastChar = key.at(-1)!;
    const noncanonical = key.slice(0, -1) + (lastChar === "c" ? "d" : "c"); // same 32 bytes, other trailing bits
    expect(Buffer.from(noncanonical, "base64url").length).toBe(32);
    for (const daemon_key of [undefined, "k", `${key}=`, noncanonical, key.replace(/.$/, "+")])
      expect(carrierTicketProblem(200, answer({ daemon_key }), 1_000)).toContain("daemon_key");
  });
});

describe("cloud journey: leaked machines (--machines, --delete-ids)", () => {
  const now = Date.UTC(2026, 10, 9, 12, 0, 0);
  const H = 3_600_000;
  const id = (n: number) => `vm_${String(n).padStart(20, "0")}`;
  const machine = (over: Record<string, unknown> = {}) => ({ id: id(1), name: "cloud journey jr-mw7vl1n7", status: "paused", created_at: now - 20 * H, last_active_at: now - 19 * H, ...over });

  test("ids are strict vm_ID@JOB_ID entries, at most 5, checked before sign-in", () => {
    expect(parseDeleteEntries(`${id(1)}@128746706182, ${id(2)}@7 ${id(1)}@128746706182`)).toEqual([{ id: id(1), job: "128746706182" }, { id: id(2), job: "7" }]);
    expect(() => parseDeleteEntries("")).toThrow("no machine ids");
    expect(() => parseDeleteEntries(" , ")).toThrow("no machine ids");
    // A bare id has no proof: refused.
    expect(() => parseDeleteEntries(id(1))).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries("vm_4817ee90a93468c689d@1")).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries(`${id(1)}@1,VM_4817EE90A93468C689D3@1`)).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries(`${id(1)}@0`)).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries(`${id(1)}@1;rm -rf /`)).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries("$(id)@1")).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries(`${id(1)}@1,${id(1)}@2`)).toThrow("given twice");
    expect(parseDeleteEntries(Array.from({ length: 5 }, (_, i) => `${id(i)}@1`).join(",")).length).toBe(5);
    expect(() => parseDeleteEntries(Array.from({ length: 6 }, (_, i) => `${id(i)}@1`).join(","))).toThrow("at most 5");
  });

  // cmux-vm run 42485334511, job 128746706182 (deploy-staging): the baseline journey made and deleted vm_962c...,
  // the journey after the deploy made vm_4817... and its cleanup delete got mutation.indeterminate.
  const JOB_LOG = [
    "2026-11-08T13:34:46.6609695Z ##[group]Run bash scripts/cmux-next/cloud-journey-ci.sh",
    "2026-11-08T13:34:47.5710994Z PASS health 886 ms :: commit 0.1.0",
    "2026-11-08T13:34:48.0205834Z PASS sign in (agent test account) 449 ms :: Stack project 454ecd03",
    "2026-11-08T13:34:53.5350164Z PASS create machine 4063 ms :: vm_962c8697bd526edb3c9f status provisioning",
    "2026-11-08T13:35:47.3129035Z PASS delete 1916 ms :: vm_962c8697bd526edb3c9f gone",
    "2026-11-08T13:35:47.3135023Z PASS staging: 25 passed, 0 failed, 3 skipped, 59.2 s",
    "2026-11-08T13:35:58.9523346Z PASS health 852 ms :: commit 0.1.0",
    "2026-11-08T13:35:59.3833812Z PASS sign in (agent test account) 431 ms :: Stack project 454ecd03",
    "2026-11-08T13:36:05.1976698Z PASS create machine 4874 ms :: vm_4817ee90a93468c689d3 status provisioning",
    "2026-11-08T13:36:08.5621120Z PASS listed 69 ms :: 6 machines",
    '2026-11-08T13:36:15.1846422Z FAIL pass Claude login 5250 ms :: exec: HTTP 502 "vm_unavailable"',
    '2026-11-08T13:36:21.9333032Z FAIL delete (cleanup) 6749 ms :: cloud.machine.delete: HTTP 200 {"code":"mutation.indeterminate","message":"the provider call was cut off; retry with the same key","retryable":true}',
    "2026-11-08T13:36:21.9335161Z FAIL staging: 8 passed, 2 failed, 0 skipped, 23.8 s",
  ].join("\r\n");

  test("a job's log proves a leak only with its journey's create of that id and a failed cleanup delete after it", () => {
    expect(leakProof(JOB_LOG, "vm_4817ee90a93468c689d3")).toBeNull();
    // Made and deleted in the same job: no failed cleanup in its own journey.
    expect(leakProof(JOB_LOG, "vm_962c8697bd526edb3c9f")).toContain("logged no failed cleanup delete");
    expect(leakProof(JOB_LOG, id(1))).toContain("no journey that made");
    // A failed cleanup of an earlier journey does not prove a later one's machine.
    const lines = JOB_LOG.split("\r\n");
    const swapped = [...lines.slice(6), ...lines.slice(0, 6)].join("\n");
    expect(leakProof(swapped, "vm_962c8697bd526edb3c9f")).toContain("logged no failed cleanup delete");
    // The cleanup line before the create, or a create outside a journey (no health step), proves nothing.
    expect(leakProof([lines[6], lines[11], lines[8]].join("\n"), "vm_4817ee90a93468c689d3")).not.toBeNull();
    expect(leakProof([lines[8], lines[11]].join("\n"), "vm_4817ee90a93468c689d3")).not.toBeNull();
    // A create that failed, or an id only quoted in another line, proves nothing.
    expect(leakProof([lines[6], lines[8].replace("PASS create", "FAIL create"), lines[11]].join("\n"), "vm_4817ee90a93468c689d3")).not.toBeNull();
    expect(leakProof([lines[6], "PASS listed 1 ms :: vm_4817ee90a93468c689d3", lines[11]].join("\n"), "vm_4817ee90a93468c689d3")).not.toBeNull();
  });

  // The real job and run (fields the proof reads), as the API answered them.
  const TRUSTED_JOB = { id: 128746706182, run_id: 42485334511, name: "deploy-staging", head_branch: "feat-cmux-next", workflow_name: "cmux VM" };
  const TRUSTED_RUN = { id: 42485334511, path: ".github/workflows/cmux-vm.yml", event: "push", head_branch: "feat-cmux-next", repository: { full_name: "manaflow-ai/cmux" }, head_repository: { full_name: "manaflow-ai/cmux" } };
  const gh = (over: { job?: any; run?: any; logStatus?: number; log?: string } = {}) => {
    const calls: Array<{ url: string; auth: string }> = [];
    const get = async (url: string, headers: Record<string, string>) => {
      calls.push({ url, auth: headers.authorization ?? "" });
      const ok = (body: unknown) => ({ status: 200, location: null, text: JSON.stringify(body) });
      if (url.endsWith("/actions/jobs/128746706182")) return ok({ ...TRUSTED_JOB, ...over.job });
      if (url.endsWith("/actions/runs/42485334511")) return ok({ ...TRUSTED_RUN, ...over.run });
      if (url.endsWith("/actions/jobs/128746706182/logs")) return { status: over.logStatus ?? 302, location: "https://blob.example/job-logs.txt?sig=x", text: "" };
      if (url.startsWith("https://blob.example/")) return { status: 200, location: null, text: over.log ?? JOB_LOG };
      return { status: 404, location: null, text: "{}" };
    };
    return { calls, get };
  };
  const entry = { id: "vm_4817ee90a93468c689d3", job: "128746706182" };

  test("the proof: a cmux-vm.yml job of this repo whose log shows the leak; the log link is read without the token", async () => {
    const g = gh();
    expect(await provenLeak(entry, "ghs_token", g.get)).toBeNull();
    expect(g.calls.find((c) => c.url.startsWith("https://blob.example/"))!.auth).toBe("");
    expect(g.calls.filter((c) => c.url.startsWith("https://api.github.com/repos/manaflow-ai/cmux/")).every((c) => c.auth === "Bearer ghs_token")).toBe(true);
  });

  test("a log a contributor's code could have written proves nothing, whatever it prints", async () => {
    // A fork's pull request: the run belongs to this repo and its workflow path is allowed, but the code is the fork's.
    const forkRun = { event: "pull_request", head_branch: "feat-cmux-next", head_repository: { full_name: "someone/cmux" } };
    expect(await provenLeak(entry, "t", gh({ run: forkRun }).get)).toContain("ran code from \"someone/cmux\"");
    expect(await provenLeak(entry, "t", gh({ run: { ...forkRun, path: ".github/workflows/backend.yml" } }).get)).not.toBeNull();
    // A pull request on this repo's own branch, a merge queue, a workflow_run, a pull_request_target: never.
    for (const event of ["pull_request", "pull_request_target", "merge_group", "workflow_run", "schedule", "", undefined]) {
      expect(await provenLeak(entry, "t", gh({ run: { event } }).get)).toContain("runs code a contributor may have written");
    }
    // A push or a dispatch on another branch (a lane branch anyone can push to).
    for (const head_branch of ["lane/x", "feat-cmux-vm-x", "main2"]) {
      expect(await provenLeak(entry, "t", gh({ run: { event: "workflow_dispatch", head_branch }, job: { head_branch } }).get)).toContain("is not feat-cmux-next or main");
    }
    expect(await provenLeak(entry, "t", gh({ run: { event: "workflow_dispatch", head_branch: "main" }, job: { head_branch: "main" } }).get)).toBeNull();
    // The run must be the job's own.
    expect(await provenLeak(entry, "t", gh({ run: { id: 1 } }).get)).toContain("did not read back");
  });

  test("no proof, no delete: another workflow, another repo, an unknown job, an unreadable log, a log without the leak", async () => {
    expect(await provenLeak(entry, "t", gh({ run: { path: ".github/workflows/manual-thing.yml" } }).get)).toContain("is not .github/workflows/cmux-vm.yml");
    expect(await provenLeak(entry, "t", gh({ run: { repository: { full_name: "someone/cmux" } } }).get)).toContain("not in manaflow-ai/cmux");
    expect(await provenLeak({ ...entry, job: "5" }, "t", gh().get)).toContain("HTTP 404");
    expect(await provenLeak(entry, "t", gh({ job: { id: 1 } }).get)).toContain("not a job of");
    expect(await provenLeak(entry, "t", gh({ job: { name: "journey-production" } }).get)).toContain("is not deploy-staging");
    expect(await provenLeak(entry, "t", gh({ logStatus: 410 }).get)).toContain("HTTP 410");
    expect(await provenLeak({ ...entry, id: "vm_962c8697bd526edb3c9f" }, "t", gh().get)).toContain("logged no failed cleanup delete");
  });

  test("the rule: only cloud journey jr-* machines, paused or failed, or old and idle", () => {
    const ok = (m: Record<string, unknown>) => journeyMachineEligible(machine(m), now).eligible;
    // A paused or failed jr- machine (and its gateway) goes.
    expect(ok({})).toBe(true);
    expect(ok({ status: "failed" })).toBe(true);
    expect(ok({ name: "cloud journey jr-mw7vl1n7 gateway" })).toBe(true);
    // An old, idle one goes, running or never active.
    expect(ok({ status: "running", created_at: now - 30 * H, last_active_at: now - 2 * H })).toBe(true);
    expect(ok({ status: "running", created_at: now - 30 * H, last_active_at: null })).toBe(true);
    // Kept never, other names never, whatever their state.
    expect(journeyMachineEligible(machine({ name: "cloud journey kept jr-mw7vl1n7" }), now)).toEqual({ eligible: false, reason: "a kept journey machine" });
    for (const name of ["cloud journey auto jr-mw7vl1n7", "my dev box", "cloud journey jr-", "cloud journey jr-ABC", "x cloud journey jr-abc", "cloud journey jr-abc gateway2", null]) expect(ok({ name })).toBe(false);
    // Running and recent never: made under 24 h ago, or active in the last 45 min.
    expect(ok({ status: "running", created_at: now - 2 * H, last_active_at: null })).toBe(false);
    expect(ok({ status: "running", created_at: now - 30 * H, last_active_at: now - 10 * 60_000 })).toBe(false);
    // A paused machine made under an hour ago may be a journey between its pause and resume.
    expect(ok({ status: "paused", created_at: now - 20 * 60_000 })).toBe(false);
    // In doubt: no.
    for (const status of ["starting", "pausing", "deleting", "deleted", undefined]) expect(ok({ status, created_at: now - 30 * H, last_active_at: null })).toBe(false);
    expect(ok({ created_at: undefined })).toBe(false);
    expect(ok({ created_at: now + H })).toBe(false);
    expect(ok({ status: "running", created_at: now - 30 * H, last_active_at: "yesterday" })).toBe(false);
    expect(ok({ id: "vm_x" })).toBe(false);
  });

  test("a list line carries what the list gives and the rule's answer", () => {
    const line = machineLine(machine({ id: "vm_4817ee90a93468c689d3", error: { code: "e", message: "m", at: 1 } }), "personal", now);
    expect(line).toEqual({ scope: "personal", id: "vm_4817ee90a93468c689d3", name: "cloud journey jr-mw7vl1n7", status: "paused", created: new Date(now - 20 * H).toISOString(), age_h: 20, last_active: new Date(now - 19 * H).toISOString(), pause_reason: null, error: "e", eligible: true, reason: "paused", find_job: expect.stringContaining("vm_4817ee90a93468c689d3@<job id>") });
    expect(machineLine(machine({ name: "cloud journey kept jr-abc" }), "personal", now).find_job).toBeUndefined();
  });

  type Fake = { scope: MachineScope; deletes: string[]; keys: string[] };
  const fake = (rows: any[], answers: Array<{ status: number; body: any }> = [{ status: 200, body: { ok: true, value: {} } }]): Fake => {
    const live = new Map(rows.map((r) => [r.id, { ...r }]));
    const deletes: string[] = [];
    const keys: string[] = [];
    return {
      deletes,
      keys,
      scope: {
        scope: "personal",
        list: async () => [...live.values()],
        get: async (m) => live.get(m) ?? null,
        remove: async (m, key) => {
          deletes.push(m);
          keys.push(key);
          const a = answers.length > 1 ? answers.shift()! : answers[0]!;
          if (a.status === 200 && a.body?.ok) live.get(m)!.status = "deleting";
          return a;
        },
      },
    };
  };
  const deps = (log: string[]) => {
    let t = now;
    return { now: () => t, sleep: async (ms: number) => { t += ms; }, log: (l: string) => log.push(l), retryMs: 180_000, readBackMs: 60_000 };
  };

  test("delete refuses an id the live list lacks, or one the rule does not allow, and then deletes nothing", async () => {
    const f = fake([machine(), machine({ id: id(2), name: "cloud journey kept jr-abc" }), machine({ id: id(3), status: "running", created_at: now - 2 * H })]);
    const log: string[] = [];
    for (const ids of [[id(1), id(9)], [id(1), id(2)], [id(3)]]) {
      const r = await deleteJourneyMachines(ids, [f.scope], "t", deps(log));
      expect(r.deleted).toEqual([]);
      expect(r.failed.length).toBe(1);
    }
    expect(f.deletes).toEqual([]);
    expect(log.some((l) => l.includes("not in the account's machine list"))).toBe(true);
    expect(log.some((l) => l.includes("a kept journey machine"))).toBe(true);
  });

  test("each delete is logged before it is sent, then read back until deleting", async () => {
    const f = fake([machine(), machine({ id: id(2), status: "failed" })]);
    const log: string[] = [];
    const sent: string[] = [];
    const scope = { ...f.scope, remove: async (m: string, k: string) => { sent.push(`delete ${m} after ${log.length} lines`); return f.scope.remove(m, k); } };
    const r = await deleteJourneyMachines([id(1), id(2)], [scope], "t", deps(log));
    expect(r).toEqual({ deleted: [id(1), id(2)], failed: [] });
    expect(JSON.parse(log[0]!)).toEqual({ before_delete: id(1), scope: "personal", name: "cloud journey jr-mw7vl1n7", status: "paused", created: new Date(now - 20 * H).toISOString(), last_active: new Date(now - 19 * H).toISOString() });
    expect(sent[0]).toBe(`delete ${id(1)} after 1 lines`);
    expect(JSON.parse(log[1]!)).toEqual({ deleted: id(1), read_back: "deleting" });
    expect(JSON.parse(log[2]!).before_delete).toBe(id(2));
  });

  test("mutation.indeterminate is retried under the same key, bounded", async () => {
    const indeterminate = { status: 409, body: { ok: false, error: { code: "mutation.indeterminate", retryable: true } } };
    const f = fake([machine()], [indeterminate, indeterminate, { status: 200, body: { ok: true, value: {} } }]);
    const r = await deleteJourneyMachines([id(1)], [f.scope], "t", deps([]));
    expect(r.deleted).toEqual([id(1)]);
    expect(f.keys.length).toBe(3);
    expect(new Set(f.keys).size).toBe(1);
    // Indeterminate for good: it stops at the bound and fails.
    const stuck = fake([machine()], [indeterminate]);
    const s = await deleteJourneyMachines([id(1)], [stuck.scope], "t", deps([]));
    expect(s.deleted).toEqual([]);
    expect(s.failed[0]!.reason).toContain("mutation.indeterminate");
    expect(stuck.deletes.length).toBeGreaterThan(3);
    expect(stuck.deletes.length).toBeLessThan(20);
    // A refusal is final: no retry, no read back.
    const refusedOnce = fake([machine()], [{ status: 409, body: { ok: false, error: { code: "cloud.machine.busy", retryable: false } } }]);
    const r2 = await deleteJourneyMachines([id(1)], [refusedOnce.scope], "t", deps([]));
    expect(r2.failed[0]!.reason).toContain("cloud.machine.busy");
    expect(refusedOnce.deletes.length).toBe(1);
  });

  test("a delete still cut off after its retries is read back, and counts as deleted when it reads deleting or gone", async () => {
    const indeterminate = { status: 409, body: { ok: false, error: { code: "mutation.indeterminate", retryable: true } } };
    for (const after of ["deleting", "gone"] as const) {
      const f = fake([machine()], [indeterminate]);
      let removed = false;
      const log: string[] = [];
      // The provider did delete it; only the answers were cut off.
      const scope = { ...f.scope, remove: async (m: string, k: string) => { removed = true; return f.scope.remove(m, k); }, get: async (m: string) => (removed ? (after === "gone" ? null : { ...machine(), status: "deleting" }) : f.scope.get(m)) };
      const r = await deleteJourneyMachines([id(1)], [scope], "t", deps(log));
      expect(r).toEqual({ deleted: [id(1)], failed: [] });
      expect(JSON.parse(log[log.length - 1]!)).toEqual({ deleted: id(1), read_back: after, after: "mutation.indeterminate" });
    }
    // A transport error the whole time, and the machine is still there: failed, naming both.
    const t = fake([machine()]);
    const down = { ...t.scope, remove: async () => { throw new Error("socket hang up"); } };
    const r = await deleteJourneyMachines([id(1)], [down], "t", deps([]));
    expect(r.failed[0]!.reason).toMatch(/transport.*after the retries, but read back still not gone/);
  });

  test("a machine that changed since the list is checked again right before its delete", async () => {
    const f = fake([machine()]);
    let reads = 0;
    const scope = { ...f.scope, get: async (m: string) => (++reads === 1 ? { ...machine(), status: "running", last_active_at: now } : f.scope.get(m)) };
    const r = await deleteJourneyMachines([id(1)], [scope], "t", deps([]));
    expect(r.deleted).toEqual([]);
    expect(r.failed[0]!.reason).toContain("not eligible at delete time");
    expect(f.deletes).toEqual([]);
  });

  test("each delete ends within its 5 min bound, whatever its requests take: 60 s deletes and 30 s reads", async () => {
    const bound = 180_000 + 120_000;
    // A fake clock and a server whose every delete answers indeterminate after 60 s and every read after 30 s,
    // unless the request's own timeout cuts it first (as AbortSignal.timeout does).
    const run = async (opts: { deleteMs: number; readMs: number; deletes: boolean }) => {
      let t = now;
      const timeouts: number[] = [];
      const slow = async (took: number, timeoutMs: number) => {
        timeouts.push(timeoutMs);
        expect(timeoutMs).toBeGreaterThan(0);
        if (took > timeoutMs) { t += timeoutMs; throw new Error(`timed out after ${timeoutMs} ms`); }
        t += took;
      };
      let removed = false;
      const scope: MachineScope = {
        scope: "personal",
        list: async () => [machine()],
        get: async (_m, timeoutMs) => { await slow(opts.readMs, timeoutMs); return removed ? { ...machine(), status: "deleting" } : machine(); },
        remove: async (_m, _k, timeoutMs) => {
          // From the third attempt on, the provider deletes it; its answer is still cut off.
          if (opts.deletes && t - now > 100_000) removed = true;
          await slow(opts.deleteMs, timeoutMs);
          return { status: 409, body: { ok: false, error: { code: "mutation.indeterminate", retryable: true } } };
        },
      };
      const sleeps: number[] = [];
      const start = t;
      const r = await deleteJourneyMachines([id(1)], [scope], "t", { now: () => t, sleep: async (ms) => { sleeps.push(ms); expect(ms).toBeGreaterThan(0); t += ms; }, log: () => undefined });
      return { r, took: t - start, timeouts, sleeps };
    };
    // Never deleted: the retries and read back run their whole time and stop at the bound, not a request past it.
    for (const [deleteMs, readMs] of [[60_000, 30_000], [59_000, 29_000], [61_000, 31_000], [1_000, 1_000]]) {
      const { r, took, timeouts } = await run({ deleteMs, readMs, deletes: false });
      expect(r.deleted).toEqual([]);
      // A 31 s read is cut at its 30 s timeout: the read before the delete fails, which deletes nothing.
      expect(r.failed[0]!.reason).toMatch(readMs > 30_000 ? /read before delete: timed out after 30000 ms/ : /by its 300 s deadline/);
      expect(took).toBeLessThanOrEqual(bound);
      for (const ms of timeouts) expect(ms).toBeLessThanOrEqual(60_000);
    }
    // Deleted on a late attempt: read back deleting within the bound.
    const late = await run({ deleteMs: 60_000, readMs: 30_000, deletes: true });
    expect(late.r.deleted).toEqual([id(1)]);
    expect(late.took).toBeLessThanOrEqual(bound);
  });

  test("no request or pause starts when less than one whole millisecond of its bound is left", async () => {
    // A clock with fractions of a millisecond, whose reads move it on a little, as time passes between a check and the call.
    const run = async (beforeMs: number) => {
      let t = now;
      const starts: Array<{ kind: string; timeoutMs: number; leftMs: number }> = [];
      // The delete's own start: the clock read just before the read before the delete (each read adds 0.1 ms).
      let retryEnd = Infinity;
      let end = Infinity;
      let reads = 0;
      const scope: MachineScope = {
        scope: "personal",
        list: async () => [machine()],
        get: async (_m, timeoutMs) => {
          if (!reads) { retryEnd = t - 0.1 + 180_000; end = retryEnd + 120_000; }
          starts.push({ kind: reads ? "read" : "before", timeoutMs, leftMs: (reads ? end : retryEnd) - t });
          // The read before the delete takes beforeMs; each read back runs to its timeout.
          t += reads++ ? timeoutMs - 0.3 : beforeMs;
          return machine();
        },
        remove: async (_m, _k, timeoutMs) => {
          starts.push({ kind: "delete", timeoutMs, leftMs: retryEnd - t });
          t += timeoutMs - 0.3;
          return { status: 409, body: { ok: false, error: { code: "mutation.indeterminate", retryable: true } } };
        },
      };
      const sleeps: number[] = [];
      const r = await deleteJourneyMachines([id(1)], [scope], "t", { now: () => (t += 0.1), sleep: async (ms) => { sleeps.push(ms); t += ms; }, log: () => undefined });
      return { r, starts, sleeps, t, end };
    };
    // The read before the delete leaves 0.5 ms of the retry window: no delete is sent at all.
    const a = await run(180_000 - 0.5);
    expect(a.starts.filter((x) => x.kind === "delete")).toEqual([]);
    // Every run: each request starts with at least 1 whole ms left and a timeout of at least 1 ms within it;
    // every pause is at least 1 ms; nothing ends past the bound.
    for (const { starts, sleeps, t, end } of [a, await run(10), await run(29_999.7)]) {
      for (const x of starts) {
        expect(x.timeoutMs).toBeGreaterThanOrEqual(1);
        expect(Number.isInteger(x.timeoutMs)).toBe(true);
        // (0.01 ms of slack for float rounding at epoch-millisecond magnitudes)
        expect(x.leftMs).toBeGreaterThanOrEqual(x.timeoutMs - 0.01);
      }
      for (const ms of sleeps) expect(ms).toBeGreaterThanOrEqual(1);
      expect(t).toBeLessThanOrEqual(end + 1);
    }
  });

  test("a delete that never reads back gone fails", async () => {
    const f = fake([machine()]);
    const scope = { ...f.scope, get: async () => machine() };
    const r = await deleteJourneyMachines([id(1)], [scope], "t", deps([]));
    expect(r.failed[0]!.reason).toContain("read back");
  });
});

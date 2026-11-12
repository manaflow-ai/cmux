import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, linkSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { claudeTranscriptModelsProgram, transcriptModels } from "./cloud-journey";
import { claudeLoginPrograms, loginBearer, loginPrograms, stubCodexAuth, validLogin, INSTALLER_SWIFT, JOURNEY_STUB_SCRIPT, MODEL_STUB_PY, newReds, probeRow, readEnvFile, resolveBackend, scrub, summaryMarkdown, swiftRawString } from "./cloud-journey";
import { oidcSignIn, waitPreflight, CODEX_STUB_CONFIG, PREFLIGHT_PROBE } from "./cloud-journey";
import { directExec, keyProbeCommand, keyProbeDetail, keyProbeStatus, parseKeyProbe, KEY_PROBE_PY } from "./cloud-journey";
import { deleteJourneyMachines, journeyMachineEligible, leakProof, machineLine, parseDeleteEntries, provenLeak, type MachineScope } from "./cloud-journey";
import { desktopLinkDial, desktopLinkVerdict, maskAddresses, rdFrame, teamIdsIn, RD_FEEDBACK } from "./cloud-journey";
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

describe("cloud journey: desktop link readback (--desktop-link)", () => {
  // A stand-in for `cmux carrier dial --service desktop`: the status line, the host's `started` frame, then its link
  // notes in the connect log; what the viewer sent goes to a file.
  const fakeDesktop = (body: string) => {
    const dir = mkdtempSync(join(tmpdir(), "journey-desktop-"));
    const bin = join(dir, "cmux");
    writeFileSync(bin, `#!/bin/bash\nprintf '%s\\n' "$*" > "${dir}/args"\nmkdir -p "$CMUX_TUI_STATE_DIR/carrier"; log="$CMUX_TUI_STATE_DIR/carrier/connect.log"\n${body}\n`, { mode: 0o755 });
    return { dir, bin };
  };
  const api = { origin: "https://api.example", bearer: "session-value", team: undefined };
  const started = `printf '\\001\\033\\000\\000\\000{"t":"started","session":1}'`;

  test("reads the link's notes from the dial's own connect log, as the viewer that keeps the session", async () => {
    const { dir, bin } = fakeDesktop(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
cat > "${"$"}{0%/*}/stdin" <&0 &
sleep 0.3; ${started}
printf 'cloud.desktop_link machine=vm_x answered\\ncloud.desktop_link machine=vm_x up\\ncloud.desktop_link machine=vm_x host_up\\n' >> "$log"
wait`);
    const r = await desktopLinkDial(bin, api, "vm_abcdefghij0123456789", 10_000, 2_000);
    expect(r.error).toBeNull();
    expect(r.lines).toEqual(["cloud.desktop_link machine=vm_x answered", "cloud.desktop_link machine=vm_x up", "cloud.desktop_link machine=vm_x host_up"]);
    expect(r.controls).toEqual(["started"]);
    expect(desktopLinkVerdict(r.lines)).toEqual({ up: true, why: "the link came up (up, host_up)" });
    expect(readFileSync(join(dir, "args"), "utf8").trim()).toBe("carrier dial --machine vm_abcdefghij0123456789 --service desktop --deadline-ms 2000");
    // The viewer's hello and start first, then feedback datagrams after `started`.
    const sent = readFileSync(join(dir, "stdin"));
    expect(sent[0]).toBe(1);
    expect(sent.toString("latin1")).toContain('"t":"hello"');
    expect(sent.toString("latin1")).toContain('"t":"start"');
    expect(sent.includes(rdFrame(2, RD_FEEDBACK))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  }, 15_000);

  test("a dial with no rd_link writes no note, and the verdict says the platform sent none", async () => {
    const { dir, bin } = fakeDesktop(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
sleep 0.5`);
    const r = await desktopLinkDial(bin, api, "vm_abcdefghij0123456789", 5_000, 2_000);
    expect(r.lines).toEqual([]);
    expect(r.error).toBe("carrier dial: ended while the desktop was open");
    expect(desktopLinkVerdict(r.lines).why).toContain("sent no rd_link");
    rmSync(dir, { recursive: true, force: true });
  });

  test("a refused dial is the error, with no note", async () => {
    const { dir, bin } = fakeDesktop(`echo '{"ok":false,"error_code":"desktop_unavailable"}' >&2
exit 1`);
    const r = await desktopLinkDial(bin, api, "vm_abcdefghij0123456789", 5_000, 2_000);
    expect(r.error).toContain("desktop_unavailable");
    expect(r.lines).toEqual([]);
    rmSync(dir, { recursive: true, force: true });
  });

  test("the verdict names an old image, a failed link, and the wire bytes match cmux-rd-proto", () => {
    expect(desktopLinkVerdict(["cloud.desktop_link machine=vm_x not_answered"]).why).toContain("cmux-rd 0.2.3");
    expect(desktopLinkVerdict(["cloud.desktop_link machine=vm_x answered", "cloud.desktop_link machine=vm_x failed no route"])).toEqual({ up: false, why: "the link did not come up: answered; failed no route" });
    // Header: version 1, kind 7 (Feedback), 14 zero bytes; payload: acked 0, decode 0, no recovery, 0 arrivals, 0 NACKs.
    expect([...RD_FEEDBACK]).toEqual([0x10, 7, ...Array(14).fill(0), ...Array(12).fill(0)]);
    expect([...rdFrame(1, Buffer.from("ab"))]).toEqual([1, 2, 0, 0, 0, 97, 98]);
    expect(maskAddresses("srflx 203.0.113.7:51820 host [2001:db8::1]:4000 vm_ab12")).toBe("srflx <addr> host <addr> vm_ab12");
    expect(teamIdsIn({ personal_team: "team_6b6623866a52063af515" }, null, { team: "team_6b6623866a52063af515" })).toEqual(["team_6b6623866a52063af515"]);
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

describe("clean-room provider key probe", () => {
  const tok = (prefix: string, n = 40) => `${prefix}${"Ab3".repeat(Math.ceil(n / 3)).slice(0, n)}`;
  const OAUTH = tok("sk-ant-oat01-");
  const PROJ = tok("sk-proj-", 32);
  const GEMINI = "AQ.Ab8RN6Jq2ZkVd0wXyP4s";
  const REFRESH = tok("rt_", 30);
  const GEMINI_SHAPE = `AIza${"Q".repeat(35)}`;
  const MISTRAL = "opaqueMistral7Kq2Zr9Lw4";
  const MISTRAL_ARG = "opaqArg8Hx3Np";
  const REFRESH_ENV = tok("rtenv_", 30);
  const REFRESH_ARG = tok("rtarg_", 30);
  const plant = (files: Record<string, string>): string => {
    const root = mkdtempSync(join(tmpdir(), "key-probe-"));
    for (const [rel, text] of Object.entries(files)) {
      const p = join(root, rel);
      mkdirSync(dirname(p), { recursive: true });
      writeFileSync(p, text);
    }
    return root;
  };
  const run = (root: string) => {
    const r = spawnSync("bash", ["-c", keyProbeCommand(readFileSync(KEY_PROBE_PY, "utf8"), ["--root", root, "--budget-s", "20", "--as-root"])], { encoding: "utf8" });
    expect(r.status).toBe(0);
    return { out: r.stdout, probe: parseKeyProbe(r.stdout) };
  };

  test("scrub removes an example of every shape the probe knows", () => {
    // One example per probe shape, by its kind. A shape added to cloud-key-probe.py without an example here fails.
    // Built at run time, like the fixtures above: a key-shaped literal in the source trips push protection.
    const examples: Record<string, string> = {
      "an Anthropic API key": tok("sk-ant-api03-", 24),
      "an Anthropic OAuth token": tok("sk-ant-oat01-", 24),
      "an Anthropic refresh token": tok("sk-ant-ort01-", 24),
      "an OpenAI project key": tok("sk-proj-", 24),
      "an OpenAI service account key": tok("sk-svcacct-", 24),
      "an OpenAI admin key": tok("sk-admin-", 24),
      "an OpenAI user key": `${tok("sk-", 20)}${["T3Bl", "bkFJ"].join("")}${tok("", 20)}`,
      "an OpenRouter key": `sk-or-v1-${"0a1b2c3d".repeat(4)}`,
      "a Google AI key": tok("AIza", 35),
      "an xAI key": tok("xai-", 40),
      "a Groq key": tok("gsk_", 40),
      "a Hugging Face token": tok("hf_", 30),
      "an AWS access key id": tok("AKIA", 16).toUpperCase(),
      "an OAuth refresh token": `"refresh_token": "${tok("", 24)}"`,
    };
    const kinds = [...readFileSync(KEY_PROBE_PY, "utf8").matchAll(/^ {4}\("([^"]+)", re\.compile\(/gm)].map((m) => m[1]);
    expect(kinds.length).toBeGreaterThan(10);
    expect(Object.keys(examples).sort()).toEqual([...kinds].sort());
    for (const [kind, example] of Object.entries(examples)) {
      const out = scrub(`detail: ${example} end`);
      expect(out, kind).toContain("[secret]");
      expect(out, kind).not.toContain(example.replace(/^"refresh_token": "/, "").replace(/"$/, ""));
    }
  });

  test("a key name in any case, a key inside a shell script's words, and a program's unshipped kinds are found", () => {
    const keys = ["Gp8Kz3Af7Le2Do0Ie9Xm4Yn1Wr6Mq5Bt", "Hq9La4Bg8Mf3Ep1Jf0Yn5Zo2Xs7Nr6Cu", "Ir0Mb5Ch9Ng4Fq2Kg1Zo6Ap3Yt8Os7Dv"];
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": `HOME=/root\0openai_api_key=${keys[0]}\0`,
      "proc/5/cmdline": `sh\0-c\0tool --mistral-api-key ${keys[1]} && run\0`,
      "proc/6/comm": "bash\n",
      "proc/6/environ": "HOME=/root\0",
      "proc/6/cmdline": `bash\0-c\0sh -c "export groq_api_key=${keys[2]}; go"\0`,
    });
    // An ELF at a shipped program's place: its Google key shape is shipped, an Anthropic key in it is not.
    const bin = join(root, "home/cmux/.local/share/cmux-tui/builds/b1/bin");
    mkdirSync(bin, { recursive: true });
    const anthropic = "sk-ant-api03-Js1Nc6Di0Oh5Gr3Lh2Ap7Bq4Zu9Pt8Ew";
    const elf = Buffer.alloc(8192);
    Buffer.from("\x7fELF", "latin1").copy(elf, 0);
    Buffer.from("AIzaSy9Kq3Lw7Lx2Mn4Bv8Rt5Hj1Fd6Gc0Pq3Zx").copy(elf, 2000);
    Buffer.from(anthropic).copy(elf, 5000);
    writeFileSync(join(bin, "tool"), elf);
    try {
      const { probe, out } = run(root);
      for (const v of [...keys, anthropic]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "cmdline process bash (1 pid): GROQ_API_KEY",
        "cmdline process bash (1 pid): MISTRAL_API_KEY",
        "env process bash (1 pid): OPENAI_API_KEY (a value)",
        "file /home/cmux/.local/share/cmux-tui/builds/[a name]/bin/[a name]: an Anthropic API key",
      ]);
      expect(probe.shipped.map((f) => f.what)).toEqual(["a Google AI key"]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("names every planted key by place and kind, and prints no value", () => {
    const root = plant({
      "proc/101/comm": "claude\n",
      "proc/101/environ": `ANTHROPIC_API_KEY=cmux-vm-edge-placeholder\0CLAUDE_CODE_OAUTH_TOKEN=${OAUTH}\0PATH=/usr/bin\0`,
      "proc/101/cmdline": "claude\0--print\0",
      "proc/102/comm": "node\n",
      "proc/102/environ": "HOME=/home/cmux\0",
      "proc/102/cmdline": `node\0--key\0${PROJ}\0`,
      // A key named on a command line, in each form: NAME=value, --name=value, --name value, and inside sh -c.
      "proc/103/comm": "env\n",
      "proc/103/environ": "",
      "proc/103/cmdline": "env\0OPENAI_API_KEY=opaque-secret-one\0tool\0",
      "proc/104/comm": "tool\n",
      "proc/104/environ": "",
      "proc/104/cmdline": "tool\0--openai-api-key=opaque2\0--GEMINI_API_KEY\0opaque3\0",
      "proc/105/comm": "sh\n",
      "proc/105/environ": "",
      "proc/105/cmdline": "sh\0-c\0cd /w && XAI_API_KEY=opaque4 run; echo OPENAI_API_KEY=$OPENAI_API_KEY\0",
      // A file and a process named with a key: found, and the name never prints the key.
      [`home/cmux/cache/${PROJ}`]: `${PROJ}\n`,
      "proc/106/comm": `${GEMINI_SHAPE}\n`,
      "proc/106/environ": `CLAUDE_CODE_OAUTH_TOKEN=${OAUTH}\0`,
      "proc/106/cmdline": "x\0",
      // Keys found by context, not shape (a refresh token in JSON, an opaque value of a key's name), named in a path
      // or a process name: found, and the name never prints them either.
      [`home/cmux/cache/${REFRESH}`]: JSON.stringify({ refresh_token: REFRESH }),
      [`home/cmux/cache/${MISTRAL}.env`]: `MISTRAL_API_KEY=${MISTRAL}\n`,
      "proc/107/comm": `${MISTRAL_ARG}\n`,
      "proc/107/environ": "",
      "proc/107/cmdline": `tool\0--mistral-api-key\0${MISTRAL_ARG}\0`,
      "proc/108/comm": "codex\n",
      "proc/108/environ": `CODEX_AUTH_JSON=${JSON.stringify({ tokens: { refresh_token: REFRESH_ENV } })}\0`,
      "proc/108/cmdline": "codex\0",
      [`home/cmux/${REFRESH_ENV}/.codex/auth.json`]: "{}",
      "proc/109/comm": `${REFRESH_ARG}\n`,
      "proc/109/environ": "",
      "proc/109/cmdline": `login\0--json\0{"refresh_token": "${REFRESH_ARG}"}\0`,
      // A key inside node_modules and inside a binary file still counts.
      "home/cmux/app/node_modules/x/.env": `ANTHROPIC_API_KEY=${tok("sk-ant-api03-")}\n`,
      "home/cmux/bin/blob": `\0\0ELF${PROJ}\0\0`,
      // Installed software's bare key shapes (what the image put in /opt, a harness's plugin cache) are listed apart, not
      // counted; a key found by its context (a refresh token's field) counts there too.
      "opt/tool/bin/blob": `\0\0ELF${PROJ}\0\0`,
      "home/cmux/.codex/.tmp/plugins/p/skills/api.md": `call it with ${PROJ}\n`,
      // AWS's documented stand-in is not a key anywhere; a real-shaped id is.
      "home/cmux/aws.txt": "id AKIAIOSFODNN7EXAMPLE\nid AKIA2E0A8F3B244C9986\n",
      "home/cmux/.claude/.credentials.json": JSON.stringify({ claudeAiOauth: { accessToken: OAUTH } }),
      "home/cmux/.codex/auth.json": JSON.stringify({ tokens: { refresh_token: REFRESH } }),
      "home/cmux/.bashrc": `export PATH=$HOME/bin:$PATH\nexport GEMINI_API_KEY=${GEMINI}\n`,
      // The model plane's placeholder and a key named in prose or as a reference are not keys.
      "etc/cmux/model-plane.env": "export OPENAI_API_KEY='cmux-vm-edge-placeholder'\nexport ANTHROPIC_API_KEY='cmux-vm-edge-placeholder'\n",
      "home/cmux/notes.md": "Set OPENAI_API_KEY before you run it: OPENAI_API_KEY=$OPENAI_API_KEY\n",
    });
    try {
      const { out, probe } = run(root);
      for (const v of [OAUTH, PROJ, GEMINI, GEMINI_SHAPE, REFRESH, REFRESH_ENV, REFRESH_ARG, MISTRAL, MISTRAL_ARG, OAUTH.slice(13, 30), PROJ.slice(8, 30), "opaque-secret-one", "opaque2", "opaque3", "opaque4"]) expect(out).not.toContain(v);
      const got = probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort();
      expect(got).toEqual([
        "cmdline process [a process] (1 pid): MISTRAL_API_KEY",
        "cmdline process [a process] (1 pid): an OAuth refresh token",
        "cmdline process env (1 pid): OPENAI_API_KEY",
        "cmdline process node (1 pid): an OpenAI project key",
        "cmdline process sh (1 pid): XAI_API_KEY",
        "cmdline process tool (1 pid): GEMINI_API_KEY",
        "cmdline process tool (1 pid): OPENAI_API_KEY",
        "env process [a process] (1 pid): CLAUDE_CODE_OAUTH_TOKEN (an Anthropic OAuth token)",
        "env process claude (1 pid): CLAUDE_CODE_OAUTH_TOKEN (an Anthropic OAuth token)",
        "env process codex (1 pid): CODEX_AUTH_JSON (an OAuth refresh token)",
        "file /home/cmux/.bashrc:2: GEMINI_API_KEY",
        "file /home/cmux/.claude/.credentials.json: a Claude login file",
        "file /home/cmux/.claude/.credentials.json:1: an Anthropic OAuth token",
        "file /home/cmux/.codex/auth.json: a Codex login file",
        "file /home/cmux/.codex/auth.json:1: an OAuth refresh token",
        "file /home/cmux/[a name].txt:2: an AWS access key id",
        "file /home/cmux/[a secret]/.codex/auth.json: a Codex login file",
        "file /home/cmux/app/node_modules/[a name]/.env:1: ANTHROPIC_API_KEY",
        "file /home/cmux/app/node_modules/[a name]/.env:1: an Anthropic API key",
        "file /home/cmux/bin/[a name]: an OpenAI project key",
        "file /home/cmux/cache/[a name].env:1: MISTRAL_API_KEY",
        "file /home/cmux/cache/[a secret]:1: an OAuth refresh token",
        "file /home/cmux/cache/[a secret]:1: an OpenAI project key",
      ]);
      expect((probe.shipped ?? []).map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/.codex/.tmp/plugins/[a name]/skills/[a name].md:1: an OpenAI project key",
        "file /opt/[a name]/bin/[a name]: an OpenAI project key",
      ]);
      expect(keyProbeDetail(probe)).toStartWith("23 findings: ");
      expect(keyProbeDetail(probe)).toContain("2 key shapes in installed software, not counted");
      expect(keyProbeStatus(probe, true)).toBe("fail");
      expect(keyProbeStatus(probe, false)).toBe("skip");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a clean machine is zero, and the probe's own source never counts as a key", () => {
    const root = plant({
      "proc/7/comm": "bash\n",
      "proc/7/environ": "HOME=/root\0OPENAI_API_KEY=cmux-vm-edge-placeholder\0",
      "proc/7/cmdline": `bash\0-c\0${keyProbeCommand(readFileSync(KEY_PROBE_PY, "utf8"))}\0`,
      "tmp/cloud-key-probe.py": readFileSync(KEY_PROBE_PY, "utf8"),
      "home/cmux/.claude/settings.json": JSON.stringify({ env: { ANTHROPIC_BASE_URL: "https://coderouter.cmux.internal" } }),
    });
    try {
      const { probe } = run(root);
      expect(probe.findings).toEqual([]);
      expect(probe.scanned.processes).toBe(1);
      expect(probe.complete).toBe(true);
      expect(keyProbeDetail(probe)).toStartWith("no provider key (");
      expect(keyProbeStatus(probe, true)).toBe("pass");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("walks folders named like pseudo file systems and follows links, each folder and file once", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/project/dev/.env": `ANTHROPIC_API_KEY=${tok("sk-ant-api03-")}\n`,
      "home/cmux/project/proc/notes": `${PROJ}\n`,
      "home/cmux/project/sys/x": "nothing here\n",
      // Outside every walked root, reached only through links.
      "usr/share/secret/key.env": `${PROJ}\n`,
      "usr/k": `${PROJ}\n`,
      "workspace/project/.env": `OPENAI_API_KEY=${MISTRAL}\n`,
    });
    // A plugin cache (whose matches are shipped) linking to a workspace, walked before the workspace itself.
    mkdirSync(join(root, "home/cmux/.claude/plugins"), { recursive: true });
    symlinkSync(join(root, "workspace/project"), join(root, "home/cmux/.claude/plugins/project"));
    symlinkSync(join(root, "usr/share/secret"), join(root, "home/cmux/linked"));
    symlinkSync(join(root, "usr/k"), join(root, "home/cmux/k.txt"));
    // A loop back to an ancestor, a second link to the same folder, and a link to nothing.
    symlinkSync(join(root, "home/cmux"), join(root, "home/cmux/project/loop"));
    symlinkSync(join(root, "usr/share/secret"), join(root, "home/cmux/project/again"));
    symlinkSync(join(root, "gone"), join(root, "home/cmux/dangling"));
    try {
      const { probe } = run(root);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/project/dev/.env:1: ANTHROPIC_API_KEY",
        "file /home/cmux/project/dev/.env:1: an Anthropic API key",
        "file /home/cmux/project/proc/[a name]:1: an OpenAI project key",
        "file /usr/[a name]:1: an OpenAI project key",
        "file /usr/share/[a name]/[a name].env:1: an OpenAI project key",
        "file /workspace/project/.env:1: OPENAI_API_KEY",
      ]);
      expect(probe.shipped ?? []).toEqual([]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a hard link in a plugin cache does not class a workspace's key as shipped", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/.env": `OPENAI_API_KEY=${MISTRAL}\n${PROJ}\n`,
    });
    // The cache is walked first; its name for the file is a second hard link, which realpath does not resolve.
    mkdirSync(join(root, "home/cmux/.claude/plugins/p"), { recursive: true });
    linkSync(join(root, "workspace/project/.env"), join(root, "home/cmux/.claude/plugins/p/.env"));
    try {
      const { probe } = run(root);
      // The cache's name is shipped for the key's shape only; the key's name given a value counts there too.
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/.claude/plugins/[a name]/.env:1: OPENAI_API_KEY",
        "file /workspace/project/.env:1: OPENAI_API_KEY",
        "file /workspace/project/.env:2: an OpenAI project key",
      ]);
      expect((probe.shipped ?? []).map((f) => f.where).sort()).toEqual(["/home/cmux/.claude/plugins/[a name]/.env:2"]);
      // Read once, reported under both names.
      expect(probe.scanned.files).toBe(1);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("the programs cmux and Codex install in a home are shipped, only while they are programs", () => {
    const elf = (text: string) => `\x7fELF\0\0${text}\0`;
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      // As on every fresh staging machine: a secret scanner's known public Google keys, Codex's copy of itself.
      "home/cmux/.local/bin/acpmux": elf(GEMINI_SHAPE),
      "home/cmux/.local/share/cmux-tui/builds/0123abcd/bin/cmux": elf(GEMINI_SHAPE),
      "home/cmux/.codex/tmp/arg0/codex-arg0Ab12/apply_patch": elf(PROJ),
      // The same names holding a script, and a program elsewhere in the home: findings.
      "home/cmux/.local/bin/cmux": `#!/bin/sh\nexport OPENAI_API_KEY=${PROJ}\n`,
      "home/cmux/.local/bin/other": elf(GEMINI_SHAPE),
    });
    try {
      const { probe } = run(root);
      expect(probe.findings.map((f) => `${f.where}: ${f.what}`).sort()).toEqual([
        "/home/cmux/.local/bin/[a name]: a Google AI key",
        "/home/cmux/.local/bin/cmux:2: OPENAI_API_KEY",
        "/home/cmux/.local/bin/cmux:2: an OpenAI project key",
      ]);
      expect((probe.shipped ?? []).map((f) => f.where).sort()).toEqual([
        "/home/cmux/.codex/tmp/arg0/[a name]/apply_patch",
        "/home/cmux/.local/bin/acpmux",
        "/home/cmux/.local/share/cmux-tui/builds/[a name]/bin/cmux",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an escaped key in JSON and a process name cut to 15 bytes never leave in the answer", () => {
    const ESCAPED = "opaqueRefresh7Kv92Npx5Rq8Lm3Dz";
    const root = plant({
      // Linux keeps a process's name to 15 bytes: the start of the key it was named after.
      "proc/5/comm": `${ESCAPED.slice(0, 15)}\n`,
      "proc/5/environ": `CODEX_AUTH_JSON={"refresh_token":"${ESCAPED}"}\0`,
      "proc/5/cmdline": "tool\0",
      "proc/6/comm": `${MISTRAL.slice(0, 15)}\n`,
      "proc/6/environ": `OPENAI_API_KEY=${MISTRAL}\0`,
      "proc/6/cmdline": "tool\0",
      // The same token, its first letter escaped in the file and spelled plainly in the file's name.
      [`home/cmux/cache/${ESCAPED}`]: `{"refresh_token":"\\u006f${ESCAPED.slice(1)}"}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [ESCAPED, ESCAPED.slice(0, 15), ESCAPED.slice(1), MISTRAL, MISTRAL.slice(0, 15)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "env process [a process] (1 pid): CODEX_AUTH_JSON (an OAuth refresh token)",
        "env process [a process] (1 pid): OPENAI_API_KEY (a value)",
        "file /home/cmux/cache/[a secret]:1: an OAuth refresh token",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a value on the line after its name is found, and a login file's token never leaves in its path", () => {
    const SPLIT = "opaqueSplit9Hq4Lx7Vn2Kw5Tz";
    const SPLIT_KEY = "opaqueSplitKey3Mv8Rq6Pn";
    const LOGIN = "opaqueLogin4Zr7Kq2Xw9Np";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/token.json": `{\n  "refresh_token":\n    "${SPLIT}"\n}\n`,
      "home/cmux/conf.json": `{"OPENAI_API_KEY":\n "${SPLIT_KEY}"}\n`,
      // The name ends the probe's first 4 MiB read and its value starts the next.
      "home/cmux/big.json": `${"a".repeat((4 << 20) - '{"refresh_token":\n'.length - 1)}\n{"refresh_token":\n"${SPLIT}"}\n`,
      // Its token on the next line, and a folder named after it; and a login file whose token has no shape at all.
      [`home/cmux/${SPLIT}/.codex/auth.json`]: `{"tokens": {"refresh_token":\n "${SPLIT}"}}\n`,
      [`home/cmux/${LOGIN}/.claude/.credentials.json`]: JSON.stringify({ claudeAiOauth: { accessToken: LOGIN } }),
    });
    try {
      const { probe, out } = run(root);
      for (const v of [SPLIT, SPLIT_KEY, LOGIN]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.where}: ${f.what}`).sort()).toEqual([
        "/home/cmux/[a name].json:1: OPENAI_API_KEY",
        "/home/cmux/[a name].json:2: an OAuth refresh token",
        "/home/cmux/[a secret]/.claude/.credentials.json: a Claude login file",
        "/home/cmux/[a secret]/.codex/auth.json: a Codex login file",
        "/home/cmux/[a secret]/.codex/auth.json:1: an OAuth refresh token",
        "/home/cmux/token.json:2: an OAuth refresh token",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an AWS credentials file's secret and a second hit's split value never leave in a path", () => {
    const AWS = "wJalrXUtnFEMIk7MDENGbPxRfiCYq9Kz4Lw8Vn2B";
    const LATE = "opaqueLate5Rk8Wq3Zn7Mv4Tx";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      [`home/cmux/${AWS}/.aws/credentials`]: `[default]\naws_access_key_id = AKIA${"Q".repeat(16)}\naws_secret_access_key = ${AWS}\n`,
      // A key name first, then a refresh token's field far along the same line, its value on the next.
      "home/cmux/late.json": `{"OPENAI_API_KEY": "", "pad": "${"p".repeat(600)}", "refresh_token":\n "${LATE}"}\n`,
      [`home/cmux/${LATE}/.codex/auth.json`]: "{}",
      "home/cmux/project/settings.ini": `aws_secret_access_key = ${AWS.slice(0, 20)}Zz9${AWS.slice(23)}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [AWS, LATE, AWS.slice(0, 15), LATE.slice(0, 15)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.where}: ${f.what}`).sort()).toEqual([
        "/home/cmux/[a name].json:1: an OAuth refresh token",
        "/home/cmux/[a secret]/.aws/credentials: an AWS credentials file",
        "/home/cmux/[a secret]/.aws/credentials:2: an AWS access key id",
        "/home/cmux/[a secret]/.aws/credentials:3: AWS_SECRET_ACCESS_KEY",
        "/home/cmux/[a secret]/.codex/auth.json: a Codex login file",
        "/home/cmux/project/[a name].ini:1: AWS_SECRET_ACCESS_KEY",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a long value on a later line is found, a large login file is read whole, and no token-like name leaves", () => {
    const LONG = `opaqueLong${"7Kq2Zr9Lw4".repeat(74)}x`; // 751 characters, longer than any one look ahead
    const BIG = "opaqueBig6Rv3Hx8Nq2Lm5";
    const MISSED = "zq81Hw4Kd9Lm2Px7"; // a token no detector names: shape alone keeps it out of the answer
    const root = plant({
      "proc/5/comm": `${MISSED.slice(0, 15)}\n`,
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/token.json": `{"refresh_token":\n "${LONG}"}\n`,
      [`home/cmux/${LONG.slice(0, 15)}/.codex/auth.json`]: "{}",
      // A valid login file over 1 MiB, its token first.
      [`home/cmux/${BIG}/.claude/.credentials.json`]: JSON.stringify({ claudeAiOauth: { accessToken: BIG }, pad: "p".repeat(2 << 20) }),
      [`home/cmux/${MISSED}/notes.txt`]: `${PROJ}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [LONG.slice(0, 15), LONG.slice(-40), BIG, MISSED, MISSED.slice(0, 15)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/[a name]/notes.txt:1: an OpenAI project key",
        "file /home/cmux/[a piece of a secret]/.codex/auth.json: a Codex login file",
        "file /home/cmux/[a secret]/.claude/.credentials.json: a Claude login file",
        "file /home/cmux/token.json:1: an OAuth refresh token",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an unknown credential leaves in no path, whatever its punctuation, and a key without digits is found", () => {
    const AT = "@zq81Hw4Kd9Lm2Px7";
    const NODIGIT = "QxTmRzLpVwNcHsJkYbFdSaGeUiOoPaWs";
    const PLUS = "ab+Zq8~Hw4=Kd9Lm2Px7";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      [`home/cmux/cache/${AT}/.codex/auth.json`]: "{}",
      [`home/cmux/cache/${PLUS}/.codex/auth.json`]: "{}",
      [`home/cmux/${NODIGIT}/.codex/auth.json`]: "{}",
      "home/cmux/project/.env": `MISTRAL_API_KEY=${NODIGIT}\n`,
      // Identifiers after a key's name are not keys.
      "home/cmux/project/config.ts": "const OPENAI_API_KEY = requiredStringValueHere\nGEMINI_API_KEY: DefaultProviderCredentials\n",
    });
    try {
      const { probe, out } = run(root);
      for (const v of [AT.slice(1), NODIGIT, PLUS, PLUS.slice(3)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.where}: ${f.what}`).sort()).toEqual([
        "/home/cmux/[a secret]/.codex/auth.json: a Codex login file",
        "/home/cmux/cache/[a name]/.codex/auth.json: a Codex login file",
        "/home/cmux/cache/[a name]/.codex/auth.json: a Codex login file",
        "/home/cmux/project/.env:1: MISTRAL_API_KEY",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a place prints only names that cannot be a credential, whatever detection saw", () => {
    const SEP = "c8Jp4k_W9q2Lt-v7X3aM_R6n8Ys"; // an opaque token with separators, under no key's name
    const root = plant({
      "proc/5/comm": `${SEP.slice(0, 15)}\n`,
      "proc/5/environ": `OPENAI_API_KEY=${MISTRAL}\0`,
      "proc/5/cmdline": "tool\0",
      "proc/6/comm": "node\n",
      "proc/6/environ": `OPENAI_API_KEY=${MISTRAL}\0`,
      "proc/6/cmdline": "node\0",
      "home/cmux/session.json": `{"access_token":"${SEP}"}\n`,
      [`home/cmux/${SEP}/.codex/auth.json`]: "{}",
      [`home/cmux/a.b/${SEP.slice(0, 6)}/${SEP.slice(7, 13)}/.codex/auth.json`]: "{}",
      // Any casing of a key's name, and a long refresh token in a binary file.
      "home/cmux/project/.env": "Mistral_Api_Key=Q8h2Fx7Kp9Wm4Rz6Lv3Bn5Nt\n",
      "home/cmux/project/blob.bin": `\0{"refresh_token":"${"Aa8k_".repeat(150)}"}`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [SEP, SEP.slice(0, 15), SEP.slice(0, 6), SEP.slice(7, 13), "Q8h2Fx7Kp9Wm4Rz6Lv3Bn5Nt", "Aa8k_Aa8k_"]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "env process [a process] (1 pid): OPENAI_API_KEY (a value)",
        "env process node (1 pid): OPENAI_API_KEY (a value)",
        "file /home/cmux/[a name]/.codex/auth.json: a Codex login file",
        "file /home/cmux/[a name]/[a name]/[a name]/.codex/auth.json: a Codex login file",
        "file /home/cmux/project/.env:1: MISTRAL_API_KEY",
        "file /home/cmux/project/[a name].bin: an OAuth refresh token",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a mark the probe wrote never shields the rest of a name, and a variable's name is shown only when plain", () => {
    const OPAQUE = "c8Jp4k_W9q2Lt-v7X3aM_R6n8Ys";
    const root = plant({
      "proc/5/comm": "tool\n",
      "proc/5/environ": `CACHE_${OPAQUE}=${PROJ}\0EXTRA_PATH=${PROJ}\0`,
      "proc/5/cmdline": "tool\0",
      "home/cmux/session.json": `{"access_token":"${OPAQUE}"}\n`,
      [`home/cmux/${GEMINI_SHAPE}-${OPAQUE}/.codex/auth.json`]: "{}",
      [`home/cmux/[a name]${OPAQUE}/.codex/auth.json`]: "{}",
    });
    try {
      const { probe, out } = run(root);
      for (const v of [OPAQUE, OPAQUE.slice(0, 15), GEMINI_SHAPE]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "env process tool (1 pid): EXTRA_PATH (an OpenAI project key)",
        "env process tool (1 pid): [a variable] (an OpenAI project key)",
        "file /home/cmux/[a name]/.codex/auth.json: a Codex login file",
        "file /home/cmux/[a name]/.codex/auth.json: a Codex login file",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a credential made only of letters leaves in no name: only listed names print", () => {
    const LOWER = "qzmtwprxvknhfgdcslybuaeioj";
    const UPPER = LOWER.toUpperCase();
    const root = plant({
      [`proc/5/comm`]: `${LOWER.slice(0, 15)}\n`,
      "proc/5/environ": `CACHE_${UPPER}=${PROJ}\0`,
      "proc/5/cmdline": "tool\0",
      "home/cmux/session.json": `{"access_token":"${LOWER}"}\n`,
      [`home/cmux/${LOWER}/.codex/auth.json`]: "{}",
      [`home/cmux/${LOWER.slice(0, 9)}/${LOWER.slice(9, 18)}/${LOWER.slice(18)}.json`]: `${PROJ}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [LOWER, UPPER, LOWER.slice(0, 15), LOWER.slice(0, 9), LOWER.slice(9, 18), LOWER.slice(18)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "env process [a process] (1 pid): [a variable] (an OpenAI project key)",
        "file /home/cmux/[a name]/.codex/auth.json: a Codex login file",
        "file /home/cmux/[a name]/[a name]/[a name].json:1: an OpenAI project key",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a name's own :digits is not a line number, an ancestor's key is read, and a binary file's held-back hit is checked", () => {
    const DIGITS = "123456789012345678901234567890123456";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      // This test's own process is an ancestor of the probe: its command line here holds a real key.
      [`proc/${process.pid}/comm`]: "supervisor\n",
      [`proc/${process.pid}/environ`]: "HOME=/root\0",
      [`proc/${process.pid}/cmdline`]: "supervisor\0--openai-api-key\0Q8h2Fx7Kp9Wm4Rz6Lv3Bn5Nt\0",
      "home/cmux/session.json": `{"access_token":"opaq:${DIGITS}"}\n`,
      [`home/cmux/opaq:${DIGITS}/.codex/auth.json`]: "{}",
      "home/cmux/project/blob.bin": `\0{"refresh_token":"${"Aa8k_".repeat(120)}\0${PROJ}\0`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [DIGITS, DIGITS.slice(0, 12), "Q8h2Fx7Kp9Wm4Rz6Lv3Bn5Nt"]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "cmdline process [a process] (1 pid): OPENAI_API_KEY",
        "file /home/cmux/[a name]/.codex/auth.json: a Codex login file",
        "file /home/cmux/project/[a name].bin: an OpenAI project key",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an escaped credential (a shell string's \\\" or JSON's \\u0022) is found as a plain one", () => {
    const refresh = "Zq8Wn3Rt6Lp2Vx9Kb5Hj1Dm4Fc7Gs0Ya";
    const named = "Qz7mRt2Kp9Vw4Xn8Lb3Hc6Jd1Fg5Ys0";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      // What a shell restores to a plain JSON login when it sources the file.
      "workspace/project/.env": `export CODEX_AUTH_JSON="{\\"tokens\\":{\\"refresh_token\\":\\"${refresh}\\"}}"\n`,
      // A JSON string holding JSON, its quotes escaped twice over, and one written as \u0022.
      "workspace/project/settings.json": `{"inner": "{\\\\\\"MISTRAL_API_KEY\\\\\\":\\\\\\"${named}A\\\\\\"}"}\n`,
      "workspace/project/other.json": `{"cfg": "{\\u0022MISTRAL_API_KEY\\u0022:\\u0022${named}B\\u0022}"}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [refresh, `${named}A`, `${named}B`]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/.env:1: an OAuth refresh token",
        "file /workspace/project/[a name].json:1: MISTRAL_API_KEY",
        "file /workspace/project/settings.json:1: MISTRAL_API_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key's name on one line and its escaped value on the next is found", () => {
    const named = "Hv5Kp8Qx2Lt7Rz4Nw9Bd3Fj6Cm1Gs0Ya";
    const aws = "Wq4Lp9Zt2Kx7Rn5Vb8Hd3Jf6Cm1Gs0YaPe7Tu";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      // The name's line has no escape; the value's line does, so only a later reading of the two lines decodes it.
      "workspace/project/conf.json": `{"MISTRAL_API_KEY":\n "\\u0048${named.slice(1)}"}\n`,
      "workspace/project/aws.json": `{"region": "x",\n  "AWS_SECRET_ACCESS_KEY":\n  "\\u0057${aws.slice(1)}"}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [named, named.slice(1), aws, aws.slice(1)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].json:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].json:2: AWS_SECRET_ACCESS_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a YAML block scalar's value is read as the key's value, in a text file and a binary one", () => {
    const literal = "Nc4Tq8Lw2Rk7Zp5Hx9Bv3Jd6Fm1Gs0Ya";
    const folded = "Pe7Xu3Kw9Lq2Rz6Vn8Hb4Jc1Dm5Fg0Ts";
    const inDb = "Ub2Wh6Ky9Pq4Rm7Xs3Lv8Jd1Fn5Gc0Za";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/config.yaml": `MISTRAL_API_KEY: |-\n  ${literal}\nother: 1\n`,
      "workspace/project/more.yml": `cloud:\n  AWS_SECRET_ACCESS_KEY: >+2 # rotated monthly\n      ${folded}\n`,
    });
    const page = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(page, 0);
    Buffer.from(`OPENAI_API_KEY: |\n  ${inDb}\n`).copy(page, 3000);
    writeFileSync(join(root, "workspace/project/c.db"), page);
    try {
      const { probe, out } = run(root);
      for (const v of [literal, folded, inDb]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].db: OPENAI_API_KEY",
        "file /workspace/project/[a name].yaml:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].yml:2: AWS_SECRET_ACCESS_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key's value behind YAML comments, tags and anchors, or nested in another assignment, is read", () => {
    const keys = ["Ra3Vk8Lq2Wz7Np5Tx9Hc4Jb6Dm1Fs0Ge", "Sb4Wl9Mr3Xa8Pq6Uy0Jd5Kc7En2Gt1Hf", "Tc5Xm0Ns4Yb9Qr7Vz1Ke6Ld8Fo3Hu2Ig", "Ud6Yn1Ot5Zc0Rs8Wa2Lf7Me9Gp4Iv3Jh", "Ve7Zo2Pu6Ad1St9Xb3Mg8Nf0Hq5Jw4Ki"];
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/a.yaml": `MISTRAL_API_KEY: # rotated monthly\n  ${keys[0]}\n`,
      "workspace/project/b.yaml": `GROQ_API_KEY: !!str ${keys[1]}\n`,
      "workspace/project/c.yaml": `XAI_API_KEY: &shared !vault |- # note\n  # the value\n  ${keys[2]}\n`,
      "workspace/project/d.js": `const env={MISTRAL_API_KEY:"${keys[3]}"};\n`,
    });
    const page = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(page, 0);
    Buffer.from(`cfg={OPENAI_API_KEY:"${keys[4]}"}`).copy(page, 3000);
    writeFileSync(join(root, "workspace/project/e.db"), page);
    try {
      const { probe, out } = run(root);
      for (const v of keys) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].db: OPENAI_API_KEY",
        "file /workspace/project/[a name].js:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].yaml:1: GROQ_API_KEY",
        "file /workspace/project/[a name].yaml:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].yaml:1: XAI_API_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key set through an index, a call, a Dockerfile, make or fish, or ended by a control byte, is read", () => {
    const keys = ["Wf8Ap3Qv7Be2Tu0Yc4Nh9Og1Ir6Kx5Lj", "Xg9Bq4Rw8Cf3Uv1Zd5Oi0Ph2Js7Ly6Mk", "Yh0Cr5Sx9Dg4Vw2Ae6Pj1Qi3Kt8Mz7Nl", "Zi1Ds6Ty0Eh5Wx3Bf7Qk2Rj4Lu9Na8Om", "Aj2Et7Uz1Fi6Xy4Cg8Rl3Sk5Mv0Ob9Pn", "Bk3Fu8Va2Gj7Yz5Dh9Sm4Tl6Nw1Pc0Qo", "Cl4Gv9Wb3Hk8Za6Ei0Tn5Um7Ox2Qd1Rp", "Dm5Hw0Xc4Il9Ab7Fj1Uo6Vn8Py3Re2Sq", "En6Ix1Yd5Jm0Bc8Gk2Vp7Wo9Qz4Sf3Tr", "Fo7Jy2Ze6Kn1Cd9Hl3Wq8Xp0Ra5Tg4Us"];
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/a.py": `os.environ["MISTRAL_API_KEY"] = "${keys[0]}"\n`,
      "workspace/project/b.js": `process.env['GROQ_API_KEY']='${keys[1]}';\n`,
      "workspace/project/c.py": `os.environ.setdefault("XAI_API_KEY", "${keys[2]}")\n`,
      "workspace/project/d.dockerfile": `FROM base\nENV MISTRAL_API_KEY ${keys[3]}\n`,
      "workspace/project/e.mk": `GROQ_API_KEY ?= ${keys[4]}\n`,
      "workspace/project/f.fish": `set -gx XAI_API_KEY ${keys[5]}\n`,
      // A call whose arguments are on their own lines: the name's line holds no `(`, the value is on the next.
      "workspace/project/i.py": `import os\nos.environ.setdefault(\n    "MISTRAL_API_KEY",\n    "${keys[8]}"\n)\n`,
    });
    // Unquoted values in a binary file, ended by a NUL or by a record's control bytes (a shell-history database row).
    const page = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(page, 0);
    Buffer.from(`MISTRAL_API_KEY=${keys[6]}\0\0`).copy(page, 3000);
    writeFileSync(join(root, "workspace/project/g.db"), page);
    const rows = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(rows, 0);
    Buffer.from(`export GROQ_API_KEY=${keys[7]}\x01\x05`).copy(rows, 5000);
    Buffer.from(`setdefault(\n  'XAI_API_KEY',\n  '${keys[9]}')`).copy(rows, 6000);
    writeFileSync(join(root, "workspace/project/h.sqlite"), rows);
    try {
      const { probe, out } = run(root);
      for (const v of keys) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].db: MISTRAL_API_KEY",
        "file /workspace/project/[a name].js:1: GROQ_API_KEY",
        "file /workspace/project/[a name].py:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].py:1: XAI_API_KEY",
        "file /workspace/project/[a name].py:3: MISTRAL_API_KEY",
        // An extension the probe does not list is part of the hidden name.
        "file /workspace/project/[a name]: GROQ_API_KEY",
        "file /workspace/project/[a name]: XAI_API_KEY",
        "file /workspace/project/[a name]:1: GROQ_API_KEY",
        "file /workspace/project/[a name]:1: XAI_API_KEY",
        "file /workspace/project/[a name]:2: MISTRAL_API_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("the budget holds inside one large file, and what that file showed is kept", () => {
    const named = "Hv5Kp8Qx2Lt7Rz4Nw9Bd3Fj6Cm1Gs0Ya";
    const dir = mkdtempSync(join(tmpdir(), "key-probe-deadline-"));
    const big = join(dir, "big.db");
    // 1 GiB, sparse: a binary file whose first read holds a key's name and value.
    writeFileSync(big, `\0OPENAI_API_KEY="${named}"\0`);
    spawnSync("truncate", ["-s", "1G", big]);
    const script = `
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
t0 = time.monotonic()
try:
    probe.scan_file(sys.argv[2], t0 + 0.05)
    print(json.dumps({"cut": False}))
except probe.OutOfTime as cut:
    print(json.dumps({"cut": True, "hits": [w for _, w in cut.hits], "s": time.monotonic() - t0}))
`;
    try {
      const r = spawnSync("python3", ["-I", "-c", script, KEY_PROBE_PY, big], { encoding: "utf8" });
      const answer = JSON.parse(r.stdout || "{}");
      expect(answer.cut).toBe(true);
      expect(answer.hits).toEqual(["OPENAI_API_KEY"]);
      // One 4 MiB read past the deadline at most, not the rest of the gigabyte.
      expect(answer.s).toBeLessThan(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a key that spells a stand-in word by chance is a key; only real stand-ins and AWS's own examples are not", () => {
    // Random keys: a stand-in word inside a run of letters and digits, and EXAMPLE inside a Google key's shape.
    const mistral = "Qd7Kx2TestMn4Lw9Vb3Rz8Hj1Fc6Gs5Yp";
    // A reference word or a stand-in word inside a key, after a separator too: still a key.
    const inside = ["Ab3Qxmyenvironment7Kq2Zr9Lw4Np5", "Ab3Qx-test-7Kq2Zr9Lw4Np5Tg8", "Ab3Qxgetenv7Kq2Zr9Lw4Np5Vh2"];
    // Every credential alphabet: base64 (`+/=`), base64url (`-_`), hex, and any printable character (a password's
    // `~!#&*`).
    const printable = ["ab+Zq8~Hw4=Kd9Lm2Px7", "Ab3!Qx#7Kq2&Zr9*Lw4"];
    const alphabets = ["Qd7+Kx2/Mn4Lw9Vb3Rz8Hj1F==", "Qd7-Kx2_Mn4Lw9Vb3Rz8Hj1Fc6", "0a1b2c3d4e5f60718293a4b5c6d7e8f9"];
    // A bracket inside a key, a key that spells the answer's own field names, and separators inside a quoted key.
    const odd = ["ab+Zq8~Hw4[Kd9Lm2Px7]", "Ab3Qxfindings7Kq2Zr9Lw4Np5", "Qd7,Kx2;Mn4)Lw9}Vb3Rz8"];
    const google = `AIza${"Sy9Kq3EXAMPLEw7Lx2Mn4Bv8Rt5Hj1Fd6Gc0".slice(0, 35)}`;
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/a.env": `MISTRAL_API_KEY=${mistral}\n`,
      "workspace/project/d.env": `GROQ_API_KEY=${inside[0]}\nXAI_API_KEY=${inside[1]}\nDEEPSEEK_API_KEY=${inside[2]}\n`,
      "workspace/project/e.env": `MISTRAL_API_KEY=${printable[0]}\nCOHERE_API_KEY=${printable[1]}\n`,
      "workspace/project/f.env": `TOGETHER_API_KEY=${alphabets[0]}\nFIREWORKS_API_KEY=${alphabets[1]}\nCEREBRAS_API_KEY=${alphabets[2]}\n`,
      "workspace/project/g.env": `PERPLEXITY_API_KEY="${odd[0]}"\nOPENROUTER_API_KEY=${odd[1]}\nDEEPSEEK_API_KEY='${odd[2]}'\n`,
      "workspace/project/b.json": `{"k": "${google}"}\n`,
      // Stand-ins: a word at the value's start or after a separator, and the exact values AWS documents.
      "workspace/project/c.env": [
        "MISTRAL_API_KEY=your-mistral-api-key-here",
        "GROQ_API_KEY=sk-test-0123456789abcdef0123",
        "XAI_API_KEY=placeholder_9f8e7d6c5b4a3210",
        "COHERE_API_KEY=process.env.COHERE_API_KEY_VALUE_1",
        "GROQ_API_KEY=${GROQ_API_KEY_FROM_VAULT_1}",
        "XAI_API_KEY={{ secrets.XAI_API_KEY_1 }}",
        "DEEPSEEK_API_KEY=os.environ.get('DEEPSEEK_API_KEY_1')",
        "AWS_SECRET_ACCESS_KEY: *cache-r2-secret-1",
        "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "id AKIAIOSFODNN7EXAMPLE",
        "",
      ].join("\n"),
    });
    try {
      const { probe, out } = run(root);
      for (const v of [mistral, google, ...inside, ...printable, ...alphabets, ...odd]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].env:1: GROQ_API_KEY",
        "file /workspace/project/[a name].env:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].env:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].env:1: PERPLEXITY_API_KEY",
        "file /workspace/project/[a name].env:1: TOGETHER_API_KEY",
        "file /workspace/project/[a name].env:2: COHERE_API_KEY",
        "file /workspace/project/[a name].env:2: FIREWORKS_API_KEY",
        "file /workspace/project/[a name].env:2: OPENROUTER_API_KEY",
        "file /workspace/project/[a name].env:2: XAI_API_KEY",
        "file /workspace/project/[a name].env:3: CEREBRAS_API_KEY",
        "file /workspace/project/[a name].env:3: DEEPSEEK_API_KEY",
        "file /workspace/project/[a name].env:3: DEEPSEEK_API_KEY",
        "file /workspace/project/[a name].json:1: a Google AI key",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a text file of one huge line is read in pieces: bounded memory, and a key across a piece's edge is found", () => {
    const dir = mkdtempSync(join(tmpdir(), "key-probe-line-"));
    const big = join(dir, "one-line.txt");
    // 64 MiB with no line break: a key's name across the first read's edge, and one deeper in. The first piece ends
    // OVERLAP bytes before the second read's end (8 MiB - 256).
    const M = 1 << 20;
    const body = Buffer.alloc(64 * M, "abc de ");
    Buffer.from(" MISTRAL_API_KEY=Qd7Kx2Mn4Lw9Vb3Rz8Hj1Fc6Gs5Yp0Ta ").copy(body, 4 * M - 266);
    Buffer.from(" GROQ_API_KEY=Xg9Bq4Rw8Cf3Uv1Zd5Oi0Ph2Js7Ly6Mk ").copy(body, 37 * M);
    writeFileSync(big, body);
    // A file whose only key's `_KEY` is split by the first piece's cut, two bytes each side: no other hit in either
    // piece reads across the cut for it.
    const cut = join(dir, "cut.txt");
    const spaces = Buffer.alloc(12 * M, " ");
    Buffer.from("XAI_API_KEY=Tc5Xm0Ns4Yb9Qr7Vz1Ke6Ld8Fo3Hu2Ig ").copy(spaces, 8 * M - 256 - 2 - "XAI_API".length);
    writeFileSync(cut, spaces);
    const script = `
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
try:
    print(json.dumps([sorted({w for _, w in probe.scan_file(f, time.monotonic() + 20)}) for f in sys.argv[2:]]))
except MemoryError:
    print(json.dumps("MemoryError"))
`;
    try {
      // Under 192 MiB: reading the line whole takes several copies of it.
      const r = spawnSync("bash", ["-c", 'ulimit -v 196608; exec python3 -I -c "$0" "$@"', script, KEY_PROBE_PY, big, cut], { encoding: "utf8" });
      expect(JSON.parse(r.stdout || "null")).toEqual([["GROQ_API_KEY", "MISTRAL_API_KEY"], ["XAI_API_KEY"]]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a line of many escapes that spell no key is read in linear time", () => {
    const dir = mkdtempSync(join(tmpdir(), "key-probe-escapes-"));
    const file = join(dir, "strings.json");
    // 400,000 escaped spaces on one line: each was a reading of the whole line, then a search back to its start
    // (4.7 s at this size, four times that at twice it). Then a key after 20,000 short lines of escapes, on its own line.
    writeFileSync(file, `{"s": "${"\\u0020".repeat(400_000)}"}\n` + `{"s": "${"\\u0020".repeat(50)}"}\n`.repeat(20_000) + `MISTRAL_API_KEY=Ab3Qx7Hw4Kd9Lm2Px7Zq8\n`);
    const script = `
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
t0 = time.monotonic()
hits = probe.scan_file(sys.argv[2])
print(json.dumps({"hits": hits, "s": time.monotonic() - t0}))
`;
    try {
      const r = spawnSync("python3", ["-I", "-c", script, KEY_PROBE_PY, file], { encoding: "utf8" });
      const answer = JSON.parse(r.stdout || "{}");
      expect(answer.hits).toEqual([[20_002, "MISTRAL_API_KEY"]]);
      expect(answer.s).toBeLessThan(1.5);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a login file of blank lines is read in linear time", () => {
    const dir = mkdtempSync(join(tmpdir(), "key-probe-login-"));
    const file = join(dir, "auth.json");
    writeFileSync(file, "\n".repeat(50_000) + "{}");
    const script = `
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
t0 = time.monotonic()
probe.login_values(sys.argv[2])
print(time.monotonic() - t0)
`;
    try {
      const r = spawnSync("python3", ["-I", "-c", script, KEY_PROBE_PY, file], { encoding: "utf8" });
      expect(Number(r.stdout)).toBeLessThan(0.5);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a huge login file is read only in part, and still names its kind", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/.codex/auth.json": "{}",
    });
    // 1 GiB, sparse: reading it whole would take a gigabyte of memory.
    spawnSync("truncate", ["-s", "1G", join(root, "home/cmux/.codex/auth.json")]);
    try {
      const r = spawnSync(
        "bash",
        ["-c", `ulimit -v 524288; ${keyProbeCommand(readFileSync(KEY_PROBE_PY, "utf8"), ["--root", root, "--budget-s", "20", "--as-root"])}`],
        { encoding: "utf8" },
      );
      expect(r.status).toBe(0);
      const probe = parseKeyProbe(r.stdout);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`)).toEqual([
        "file /home/cmux/.codex/auth.json: a Codex login file",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("the budget holds across many hits in one file, each with a value left open", () => {
    const named = "Hv5Kp8Qx2Lt7Rz4Nw9Bd3Fj6Cm1Gs0Ya";
    const dir = mkdtempSync(join(tmpdir(), "key-probe-hits-"));
    const many = join(dir, "many.env");
    // 20,000 names whose value is open at the line's end, each read ahead past its line: a key first, then the rest.
    writeFileSync(many, `OPENAI_API_KEY=${named}\n` + "OPENAI_API_KEY=\n".repeat(20_000));
    const script = `
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
t0 = time.monotonic()
try:
    probe.scan_file(sys.argv[2], t0 + 0.05)
    print(json.dumps({"cut": False, "s": time.monotonic() - t0}))
except probe.OutOfTime as cut:
    print(json.dumps({"cut": True, "hits": [w for _, w in cut.hits], "s": time.monotonic() - t0}))
`;
    try {
      const r = spawnSync("python3", ["-I", "-c", script, KEY_PROBE_PY, many], { encoding: "utf8" });
      const answer = JSON.parse(r.stdout || "{}");
      expect(answer.cut).toBe(true);
      expect(answer.hits).toContain("OPENAI_API_KEY");
      expect(answer.s).toBeLessThan(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("any ASCII character JSON writes as \\u00XX is read as itself, in a text file and a binary one", () => {
    const named = "Hv5Kp8Qx2Lt7Rz4Nw9Bd3Fj6Cm1Gs0Ya";
    const proj = PROJ.replace("sk-", "sk\\u002d");
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/conf.json": `{"OPENAI\\u005fAPI\\u005fKEY":"${named}"}\n`,
    });
    const page = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(page, 0);
    Buffer.from(`{"k":"${proj}"}`).copy(page, 3000);
    writeFileSync(join(root, "workspace/project/c.db"), page);
    try {
      const { probe, out } = run(root);
      expect(out).not.toContain(named);
      expect(out).not.toContain(PROJ.slice(8));
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].db: an OpenAI project key",
        "file /workspace/project/[a name].json:1: OPENAI_API_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("in a binary file, a \\u0022-escaped refresh token's field and an escaped one longer than a hit's span are found", () => {
    const short = "Mx4Tq9Ld2Wv7Rk5Ns8Pb3Hz6Jc1Fg0Ya";
    const long = "Aa8k_".repeat(150);
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
    });
    const db = (row: string) => {
      const page = Buffer.alloc(8192);
      Buffer.from("SQLite format 3\0").copy(page, 0);
      Buffer.from(row).copy(page, 4000);
      return page;
    };
    mkdirSync(join(root, "workspace/project"), { recursive: true });
    writeFileSync(join(root, "workspace/project/a.db"), db(`{"inner":"{\\u0022refresh_token\\u0022:\\u0022${short}\\u0022}"}`));
    writeFileSync(join(root, "workspace/project/b.db"), db(JSON.stringify({ inner: JSON.stringify({ refresh_token: long }) })));
    try {
      const { probe, out } = run(root);
      expect(out).not.toContain(short);
      expect(out).not.toContain(long.slice(0, 40));
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].db: an OAuth refresh token",
        "file /workspace/project/[a name].db: an OAuth refresh token",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key's name across a binary file's 4 MiB reads counts, and a refresh token's field counts in installed software", () => {
    const opaque = "Wv4Nq8Rt2Lp6Zx9Kb3Hj7Dm5Fc1Gs0";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "opt/tool/.env": `CODEX_AUTH_JSON='{"tokens":{"refresh_token":"${opaque}R"}}'\n`,
    });
    // A binary file whose JSON assignment starts 32 bytes before the first read's end: the value runs into the next.
    const edge = 4 << 20;
    const row = Buffer.from(`{"MISTRAL_API_KEY":"${opaque}B${"q7".repeat(40)}"}`);
    const file = Buffer.alloc(edge + 4096);
    Buffer.from("SQLite format 3\0").copy(file, 0);
    row.copy(file, edge - 32);
    mkdirSync(join(root, "workspace/project"), { recursive: true });
    writeFileSync(join(root, "workspace/project/settings.db"), file);
    try {
      const { probe, out } = run(root);
      expect(out).not.toContain(`${opaque}B`);
      expect(out).not.toContain(`${opaque}R`);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /opt/[a name]/.env:1: an OAuth refresh token",
        "file /workspace/project/[a name].db: MISTRAL_API_KEY",
      ]);
      expect(probe.shipped ?? []).toEqual([]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key's name given a secret counts in a database file and in installed software's folders", () => {
    const opaque = "Qz7mRt2Kp9Vw4Xn8Lb3Hc6Jd1Fg5Ys0";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "opt/tool/.env": `OPENAI_API_KEY=${opaque}A\n`,
      "home/cmux/.claude/plugins/custom/.env": `OPENAI_API_KEY=${opaque}B\n`,
    });
    // A SQLite file: a binary page holding a settings row's JSON.
    const page = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(page, 0);
    Buffer.from(`{"MISTRAL_API_KEY":"${opaque}C"}`).copy(page, 5000);
    mkdirSync(join(root, "workspace/project"), { recursive: true });
    writeFileSync(join(root, "workspace/project/settings.db"), page);
    try {
      const { probe, out } = run(root);
      for (const tail of ["A", "B", "C"]) expect(out).not.toContain(opaque + tail);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/.claude/plugins/[a name]/.env:1: OPENAI_API_KEY",
        "file /opt/[a name]/.env:1: OPENAI_API_KEY",
        "file /workspace/project/[a name].db: MISTRAL_API_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a login file named across a linked folder the walk already read counts, at any depth", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/cache/auth.json": `{"access_token":"opaqueAccess7Kq2Zr9Lw4"}\n`,
      "home/cmux/gc/gcloud/application_default_credentials.json": `{"refresh_token":"opaqueRefresh8Vb3Np6Ht1"}\n`,
      "workspace/project/README.md": "\n",
    });
    // /home is walked before /workspace: both links lead into folders already read under other names.
    symlinkSync(join(root, "home/cmux/cache"), join(root, "workspace/project/.codex"));
    symlinkSync(join(root, "home/cmux/gc"), join(root, "workspace/project/.config"));
    try {
      const { probe, out } = run(root);
      expect(out).not.toContain("opaqueAccess7Kq2Zr9Lw4");
      expect(out).not.toContain("opaqueRefresh8Vb3Np6Ht1");
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/[a name]/gcloud/application_default_credentials.json:1: an OAuth refresh token",
        "file /workspace/project/.codex/auth.json: a Codex login file",
        "file /workspace/project/.config/gcloud/application_default_credentials.json: a Google Cloud login file",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a home's login file behind a link to a folder already read still counts, and a project's plugins folder is no cache", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/cache/auth.json": `{"access_token":"opaqueAccess7Kq2Zr9Lw4"}\n`,
      "workspace/project/.claude/plugins/custom/.env": `OPENAI_API_KEY=${PROJ}\n`,
      "root/.profile": "\n",
    });
    // /root is walked after /home: its .codex is the cache folder the walk has already read.
    symlinkSync(join(root, "home/cmux/cache"), join(root, "root/.codex"));
    try {
      const { probe, out } = run(root);
      expect(out).not.toContain("opaqueAccess7Kq2Zr9Lw4");
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /root/.codex/auth.json: a Codex login file",
        "file /workspace/project/.claude/plugins/[a name]/.env:1: OPENAI_API_KEY",
        "file /workspace/project/.claude/plugins/[a name]/.env:1: an OpenAI project key",
      ]);
      expect(probe.shipped ?? []).toEqual([]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key glued into a file's name never leaves in the answer", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      [`home/cmux/cache/prefix_${GEMINI_SHAPE}`]: `${GEMINI_SHAPE}\n`,
      [`home/cmux/cache/x${PROJ}y`]: `${PROJ}\n`,
    });
    try {
      const { probe, out: stdout } = run(root);
      for (const v of [GEMINI_SHAPE, PROJ]) expect(stdout).not.toContain(v);
      expect(probe.findings.map((f) => f.what).sort()).toEqual(["a Google AI key", "an OpenAI project key"]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("no finding with a gap in what was read is unknown: a clean check fails it", () => {
    const root = plant({ "proc/9/comm": "bash\n", "proc/9/environ": "HOME=/root\0", "proc/9/cmdline": "bash\0", "home/cmux/locked": "x" });
    try {
      // Not root: a gap on its own.
      // python3 straight, not keyProbeCommand: that one takes sudo where it can, and root reads every file.
      const direct = (...args: string[]) => spawnSync("python3", ["-I", KEY_PROBE_PY, "--root", root, ...args], { encoding: "utf8" });
      const notRoot = direct();
      const a = parseKeyProbe(notRoot.stdout);
      if (process.getuid?.() !== 0) {
        expect(a.findings).toEqual([]);
        expect(a.complete).toBe(false);
        expect(a.gaps).toContain("not run as root");
        expect(keyProbeStatus(a, true)).toBe("fail");
        expect(keyProbeStatus(a, false)).toBe("skip");
        expect(keyProbeDetail(a)).toContain("unknown");
      }
      // A process still there whose environment cannot be read, and a file that cannot be read.
      spawnSync("chmod", ["000", join(root, "proc/9/environ"), join(root, "home/cmux/locked")]);
      const b = parseKeyProbe(direct("--as-root").stdout);
      if (process.getuid?.() !== 0) {
        expect(b.complete).toBe(false);
        expect(b.gaps).toEqual(["1 processes unreadable", "1 files unreadable"]);
        expect(keyProbeStatus(b, true)).toBe("fail");
      }
      // A walk that runs out of budget.
      const c = parseKeyProbe(direct("--as-root", "--budget-s", "0").stdout);
      expect(c.truncated).toBe(true);
      expect(keyProbeStatus(c, true)).toBe("fail");
    } finally {
      spawnSync("chmod", ["-R", "u+rwX", root]);
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("scrub removes provider keys from any text the journey records", () => {
    const text = `probe printed ${OAUTH} and ${PROJ} at /x/${GEMINI_SHAPE} and /cache/prefix_${GEMINI_SHAPE}_${tok("hf_", 30)}`;
    const out = scrub(text);
    for (const v of [OAUTH, PROJ, GEMINI_SHAPE, "AIza", "hf_"]) expect(out).not.toContain(v);
    expect(out).toContain("[secret]");
  });

  test("the machine exec route's HTTP request waits as long as the command may run", async () => {
    const waits: (number | undefined)[] = [];
    const api = {
      raw: async (_m: string, route: string, _b?: unknown, timeoutMs?: number) => {
        waits.push(timeoutMs);
        if (route.endsWith("/client-session")) return { status: 501, body: { error: { code: "cloud.provider.unsupported" } } };
        return { status: 200, body: { value: { ok: true, exitCode: 0, stdout: "x", stderr: "" } } };
      },
    } as any;
    await directExec(api, "m1", { secrets: [] } as any)("true", 290_000);
    expect(waits[1]).toBeGreaterThanOrEqual(290_000);
  });

  test("an answer without the marker line is an error, not a clean machine", () => {
    expect(() => parseKeyProbe("python3: command not found\n")).toThrow("printed no answer");
  });
});

// The "session model" step reads what ran from the session's Claude transcript, wherever the agent's Claude
// directory is: ~/.claude, or ~/.config/cmux/claude-team (agent-auth.sh's team and gateway modes on a shared machine).
describe("claudeTranscriptModelsProgram", () => {
  const id = "0b6c2f5e-9d1a-4c3e-8f00-1234567890ab";
  const run = (home: string, env: Record<string, string> = {}) =>
    spawnSync("bash", ["-c", claudeTranscriptModelsProgram(id)], { encoding: "utf8", env: { PATH: process.env.PATH ?? "", HOME: home, ...env } }).stdout;
  const transcript = (dir: string, models: string[]) => {
    const project = join(dir, "projects", "-home-cmux-chats-x");
    spawnSync("mkdir", ["-p", project]);
    writeFileSync(join(project, `${id}.jsonl`), models.map((m) => JSON.stringify({ type: "assistant", message: { model: m, role: "assistant" } })).join("\n") + "\n");
  };
  test("finds the transcript in the claude-team directory a team or gateway agent runs with", () => {
    const home = mkdtempSync(join(tmpdir(), "journey-claude-team-"));
    try {
      transcript(join(home, ".config/cmux/claude-team"), ["claude-sonnet-5-5", "<synthetic>"]);
      expect(transcriptModels(run(home))).toEqual(["claude-sonnet-5-5"]);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
  test("finds it in ~/.claude and in CLAUDE_CONFIG_DIR, and names every model that ran", () => {
    const home = mkdtempSync(join(tmpdir(), "journey-claude-home-"));
    try {
      transcript(join(home, ".claude"), ["claude-haiku-5-5"]);
      transcript(join(home, "elsewhere"), ["claude-opus-5-5"]);
      expect(transcriptModels(run(home)).sort()).toEqual(["claude-haiku-5-5"]);
      expect(transcriptModels(run(home, { CLAUDE_CONFIG_DIR: join(home, "elsewhere") })).sort()).toEqual(["claude-haiku-5-5", "claude-opus-5-5"]);
      expect(transcriptModels(run(join(home, "none")))).toEqual([]);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});

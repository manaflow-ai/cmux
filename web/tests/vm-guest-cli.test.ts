import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";

// Every shim run spawns dozens of processes (sh + jq per step); give the suites room.
setDefaultTimeout(60_000);
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { createServer } from "node:net";
import { join } from "node:path";

import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH, guestCliInstallCommand } from "../services/vms/guestCli";

/**
 * Runs the shim against a fake cmux-tui binary that prints its argv one word
 * per line, so a test can assert exactly what would reach the daemon.
 */
function runShim(
  args: string[],
  env: Record<string, string | undefined> = {},
  setup?: (directory: string) => void,
): { argv: string[]; status: number | null; stdout: string; stderr: string } {
  const dir = mkdtempSync(join(tmpdir(), "cmux-guest-cli-"));
  const shim = join(dir, "cmux");
  const fakeTui = join(dir, "cmux-tui");
  writeFileSync(shim, GUEST_CMUX_SHIM);
  chmodSync(shim, 0o755);
  writeFileSync(fakeTui, '#!/bin/sh\nprintf \'%s\\n\' "$@"\n');
  chmodSync(fakeTui, 0o755);
  setup?.(dir);
  const inheritedPath = env.PATH ?? process.env.PATH ?? "/usr/bin:/bin";
  const result = spawnSync("sh", [shim, ...args], {
    encoding: "utf8",
    timeout: 12_000,
    env: { NODE_ENV: "test", HOME: dir, CMUX_TUI_BIN: fakeTui, ...env, PATH: `${dir}:${inheritedPath}` },
  });
  const argv = result.stdout.length === 0 ? [] : result.stdout.replace(/\n$/, "").split("\n");
  return { argv, status: result.status, stdout: result.stdout, stderr: result.stderr };
}

const TERMINAL_ID = "term_0123456789abcdef0123456789abcdef";

// The in-VM `cmux` shim is shipped as driver-written bytes; a syntax error
// would surface only inside a live machine, so validate it here.
describe("in-VM cmux shim", () => {
  test.each(["existing", "create", "create-failed", "missing-id"])("peer exec selects a supported workspace and fails closed (%s)", async (mode) => {
    const directory = mkdtempSync(join(tmpdir(), "cmux-peer-exec-"));
    const socket = join(directory, "peer.sock");
    const server = createServer();
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(socket, resolve);
      });
      const peers = join(directory, ".cmux", "peers");
      const links = join(directory, ".cmux", "peer-links");
      mkdirSync(peers, { recursive: true });
      mkdirSync(links, { recursive: true });
      writeFileSync(join(peers, "peer.json"), "{}");
      writeFileSync(join(links, "peer.sock-path"), socket);
      writeFileSync(join(links, "peer.pid"), String(process.pid));
      const shim = join(directory, "cmux");
      const daemon = join(directory, "cmux-tui");
      writeFileSync(shim, GUEST_CMUX_SHIM);
      writeFileSync(daemon, `#!/bin/sh
printf '%s\\n' "$*" >> "$HOME/calls"
case "$*" in
  *"workspace current show") [ "$MODE" = existing ] ;;
  *"workspace create --name main")
    [ "$MODE" != create-failed ] || exit 74
    if [ "$MODE" = missing-id ]; then printf '{}'; else printf '{"value":{"workspace_id":"ws_created"}}'; fi ;;
  *"workspace current run "*|*"workspace ws_created run "*) printf '%s\\n' "$*" ;;
  *) exit 91 ;;
esac
`);
      chmodSync(daemon, 0o755);
      const result = spawnSync("sh", [shim, "vm", "exec", "peer", "--", "printf", "hello"], {
        encoding: "utf8",
        timeout: 10_000,
        env: { NODE_ENV: "test", PATH: process.env.PATH, HOME: directory, CMUX_TUI_BIN: daemon, MODE: mode },
      });
      const calls = readFileSync(join(directory, "calls"), "utf8");
      expect(calls).toContain("workspace current show");
      if (mode === "existing") {
        expect(result.status).toBe(0);
        expect(calls).not.toContain("workspace create");
        expect(result.stdout).toContain("workspace current run");
      } else if (mode === "create") {
        expect(result.status).toBe(0);
        expect(result.stdout).toContain("workspace ws_created run");
      } else {
        expect(result.status).toBe(3);
        expect(calls).not.toContain(" run ");
      }
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      rmSync(directory, { recursive: true, force: true });
    }
  });

  test("localizes help and interpolated errors using the guest locale", () => {
    const help = runShim(["--help"], { LANG: "ja_JP.UTF-8" });
    expect(help.status).toBe(0);
    expect(help.stdout).toContain("クラウド");
    const invalid = runShim(["auth", "status", "--invalid"], { LC_MESSAGES: "ja_JP.UTF-8" });
    expect(invalid.status).toBe(2);
    expect(invalid.stderr).toContain("不明なオプション");
    expect(invalid.stderr).toContain("--invalid");
  });

  test("LC_ALL overrides other locale settings and unknown locales use English", () => {
    const overridden = runShim(["--help"], { LC_ALL: "C", LC_MESSAGES: "ja_JP.UTF-8", LANG: "ja_JP.UTF-8" });
    expect(overridden.status).toBe(0);
    expect(overridden.stdout).toContain("Cloud workspace CLI");
    const fallback = runShim(["auth", "status", "--invalid"], { LANG: "fr_FR.UTF-8" });
    expect(fallback.stderr).toContain("unknown option --invalid");
  });

  test.each([true, false])("peer connection consumes readiness or process exit (ready=%s)", (ready) => {
    let fixtureDirectory = "";
    try {
      const result = runShim(["vm", "connect", "peer"], {}, (directory) => {
        fixtureDirectory = directory;
        const peerDirectory = join(directory, ".cmux", "peers");
        mkdirSync(peerDirectory, { recursive: true });
        writeFileSync(join(peerDirectory, "peer.json"), JSON.stringify({ route: "test-route", invite: "one-use-invite" }));
        const client = join(directory, "client.cjs");
        writeFileSync(client, ready ? `
          const net = require("node:net");
          const socket = require("node:path").join(process.env.HOME, "peer.sock");
          const server = net.createServer();
          server.listen(socket, () => {
            process.stdout.write(JSON.stringify({ event: "connecting" }) + "\\n");
            process.stdout.write(JSON.stringify({ event: "connection-snapshot", local_socket: socket }) + "\\n");
          });
        ` : 'process.stderr.write("connection refused\\n"); process.exit(7);');
        writeFileSync(join(directory, "cmux-tui"), `#!/bin/sh\nexec '${process.execPath}' '${client}'\n`);
      });
      expect(result.status).toBe(ready ? 0 : 3);
      if (ready) {
        expect(result.stdout).toContain("OK connected peer socket=");
        const peer = JSON.parse(readFileSync(join(fixtureDirectory, ".cmux", "peers", "peer.json"), "utf8"));
        expect(peer.invite).toBeUndefined();
      } else {
        expect(result.stderr).toContain("link to 'peer' exited");
      }
    } finally {
      for (const filename of ["peer.pid", "peer.events.pid"]) {
        try {
          const processID = Number(readFileSync(join(fixtureDirectory, ".cmux", "peer-links", filename), "utf8"));
          if (Number.isInteger(processID) && processID > 1) process.kill(processID, "SIGTERM");
        } catch {}
      }
      if (fixtureDirectory) rmSync(fixtureDirectory, { recursive: true, force: true });
    }
  });

  test("is valid POSIX sh", () => {
    const result = spawnSync("sh", ["-n"], { input: GUEST_CMUX_SHIM, encoding: "utf8" });
    expect(result.stderr).toBe("");
    expect(result.status).toBe(0);
  });

  test("fronts the machine's own cmux-tui and the peer-link verbs", () => {
    // Local verbs forward to the daemon binary on the daemon's session.
    expect(GUEST_CMUX_SHIM).toContain("/root/.cmux/bin/cmux-tui");
    expect(GUEST_CMUX_SHIM).toContain('--session "$LOCAL_SESSION"');
    // Peer links ride the same headless connect contract the Mac app uses:
    // remote connect --headless --json, socket named by the
    // connection-snapshot event's local_socket field.
    expect(GUEST_CMUX_SHIM).toContain("remote connect");
    expect(GUEST_CMUX_SHIM).toContain("--headless --json");
    expect(GUEST_CMUX_SHIM).toContain('select(.event=="connection-snapshot")');
    expect(GUEST_CMUX_SHIM).toContain(".local_socket");
    // The single-use invitation travels by file, never argv, and is dropped
    // from the peer file once consumed.
    expect(GUEST_CMUX_SHIM).toContain("--invite-file");
    expect(GUEST_CMUX_SHIM).toContain("del(.invite)");
    // Peer exec runs through a durable terminal on the peer, creating a
    // workspace when the fresh session has none.
    expect(GUEST_CMUX_SHIM).toContain('workspace "$target" run --on-exit close');
    expect(GUEST_CMUX_SHIM).toContain("workspace create --name main");
  });

  test("help exposes the shared auth, CodeRouter, and agent contract", () => {
    const run = runShim(["--help"]);
    expect(run.status).toBe(0);
    expect(run.stdout).toContain("cmux auth status [--json]");
    expect(run.stdout).toContain("cmux coderouter status|usage [--json]|models");
    expect(run.stdout).toContain("cmux coderouter agent <claude|codex|opencode|pi>");
    expect(run.stdout).toContain("cmux agent <claude|codex|opencode|pi>");
  });

  describe("auth status", () => {
    const fakeCurl = (status: string, body = "") => (directory: string) => {
      const curl = join(directory, "curl");
      writeFileSync(
        curl,
        `#!/bin/sh\ncase "$*" in\n  *-w*) printf '%s' '${status}' ;;\n  *) printf '%s' '${body.replace(/'/g, "'\\''")}' ;;\nesac\n`,
      );
      chmodSync(curl, 0o755);
    };

    test("reports daemon and accepted VM-bound route without exposing a token", () => {
      const run = runShim(
        ["auth", "status", "--json"],
        {
          CMUX_CODEROUTER_URL: "https://coderouter.cmux.internal",
          OPENAI_API_KEY: "cmux-vm-edge-placeholder",
        },
        fakeCurl("200"),
      );
      expect(run.status).toBe(0);
      const payload = JSON.parse(run.stdout) as Record<string, any>;
      expect(payload.authenticated).toBe(true);
      expect(payload.daemon).toMatchObject({ running: true, authenticated: true, session: "cloud" });
      expect(payload.tls).toEqual({ reachable: true });
      expect(payload.coderouter).toMatchObject({ configured: true, route_authenticated: "accepted", http_status: "200" });
      expect(run.stdout).not.toContain("crt_");
    });

    test("separates TLS reachability from a rejected route", () => {
      const run = runShim(
        ["auth", "status", "--json"],
        { CMUX_CODEROUTER_URL: "https://coderouter.cmux.internal" },
        fakeCurl("401"),
      );
      expect(run.status).not.toBe(0);
      const payload = JSON.parse(run.stdout) as Record<string, any>;
      expect(payload.authenticated).toBe(false);
      expect(payload.daemon.authenticated).toBe(true);
      expect(payload.tls).toEqual({ reachable: true });
      expect(payload.coderouter).toMatchObject({ route_authenticated: "rejected", http_status: "401" });
    });

    test("does not claim full authentication when the model plane is absent", () => {
      const run = runShim(["auth", "status", "--json"]);
      expect(run.status).not.toBe(0);
      const payload = JSON.parse(run.stdout) as Record<string, any>;
      expect(payload.authenticated).toBe(false);
      expect(payload.daemon).toMatchObject({ running: true, authenticated: true });
      expect(payload.coderouter).toMatchObject({ configured: false, route_authenticated: "not_configured" });
    });

    test("refuses a route token copied into the guest", () => {
      const run = runShim(
        ["auth", "status"],
        { OPENAI_API_KEY: "crt_should_not_be_here" },
      );
      expect(run.status).not.toBe(0);
      expect(run.stderr).toContain("refusing a coderouter route token");
    });
  });

  describe("CodeRouter agent entrypoints", () => {
    const usageDays = (): { day: string; totalTokens: number; apiEquivalentUsd: number }[] => {
      const days = [];
      for (let offset = 29; offset >= 0; offset -= 1) {
        const date = new Date(Date.UTC(2026, 8, 10 - offset));
        days.push({ day: date.toISOString().slice(0, 10), totalTokens: 0, apiEquivalentUsd: 0 });
      }
      days[21] = { day: "2026-09-02", totalTokens: 400_000, apiEquivalentUsd: 3.5 };
      days[28] = { day: "2026-09-09", totalTokens: 1_234_567, apiEquivalentUsd: 12.3456 };
      days[29] = { day: "2026-09-10", totalTokens: 68_612, apiEquivalentUsd: 0.004 };
      return days;
    };
    const USAGE = {
      vmId: "28e987ce-549f-4040-8489-5ed3789faf3e",
      displayName: "toasty-beige-husky",
      periodDays: 30,
      kind: "ready",
      asOf: "2026-09-10T23:24:01.425Z",
      totals: { inputTokens: 1_700_000, cachedInputTokens: 14_848, outputTokens: 3_179, totalTokens: 1_703_179, apiEquivalentUsd: 15.8456 },
      days: usageDays(),
    };
    const USAGE_BODY = JSON.stringify(USAGE);
    const usageCurl = (body: string) => (directory: string) => {
      const curl = join(directory, "curl");
      writeFileSync(curl, `#!/bin/sh\ncase "$*" in\n  *vm-usage/self*) printf '%s' '${body}' ;;\n  *) exit 1 ;;\nesac\n`);
      chmodSync(curl, 0o755);
    };
    // "now" pinned 30 minutes after asOf so the relative age is deterministic.
    const USAGE_ENV = { CMUX_CODEROUTER_URL: "https://coderouter.cmux.internal", CMUX_NOW_EPOCH: String(Date.parse("2026-09-10T23:54:01Z") / 1000) };

    test("renders usage for people and agents: labeled lines, trend, one row per day with usage, hints", () => {
      const run = runShim(["coderouter", "usage"], USAGE_ENV, usageCurl(USAGE_BODY));
      expect(run.status).toBe(0);
      expect(run.stdout).toBe([
        "CodeRouter usage for toasty-beige-husky, last 30 days (as of 30 min ago, 2026-09-10 23:24 UTC)",
        "machine  toasty-beige-husky  28e987ce-549f-4040-8489-5ed3789faf3e",
        "tokens   1,703,179 total = 1,700,000 input (14,848 cached) + 3,179 output",
        "cost     $15.85 API-equivalent  (list-price value of these tokens, not a bill)",
        "trend    last 7 days 1,303,179 tokens, prior 7 days 400,000",
        "",
        "day            tokens    cost",
        "2026-09-02    400,000   $3.50  ████",
        "2026-09-09  1,234,567  $12.35  ████████████",
        "2026-09-10     68,612  <$0.01  █",
        "Days without usage are not listed (27 of 30).",
        "",
        "Machine-readable JSON: cmux coderouter usage --json",
        "Team view: https://cmux.com/dashboard/coderouter",
        "",
      ].join("\n"));
    });

    test("usage breaks spend down per workspace (named through cmux-tui), agent, and model", () => {
      const totals = (totalTokens: number) => ({ inputTokens: totalTokens, cachedInputTokens: 0, outputTokens: 0, totalTokens, apiEquivalentUsd: totalTokens / 100_000 });
      const body = {
        ...USAGE,
        workspaces: [
          { workspaceId: "ws_a", totals: totals(1_200_000) },
          { workspaceId: "ws_b", totals: totals(400_000) },
          { workspaceId: null, totals: totals(103_179) },
        ],
        terminals: [{ workspaceId: "ws_a", surfaceId: "sf_1", totals: totals(1_200_000) }],
        agents: [{ agent: "claude", totals: totals(1_300_000) }, { agent: "codex", totals: totals(403_179) }],
        models: [
          { model: "claude-sonnet-5", totals: totals(1_200_000) },
          { model: "gpt-5.6", totals: totals(403_179) },
          { model: "claude-haiku-4-5", totals: totals(100_000) },
        ],
      };
      const run = runShim(["coderouter", "usage"], USAGE_ENV, (directory) => {
        usageCurl(JSON.stringify(body))(directory);
        writeFileSync(join(directory, "cmux-tui"), "#!/bin/sh\nprintf '%s' '{\"workspaces\":[{\"id\":\"ws_a\",\"name\":\"chatmux\"},{\"id\":\"ws_zzz\",\"name\":\"idle\"}]}'\n");
      });
      expect(run.status).toBe(0);
      expect(run.stdout).toContain([
        "trend      last 7 days 1,303,179 tokens, prior 7 days 400,000",
        "workspace  chatmux 1,200,000 (70%)   closed workspaces 400,000 (23%)   outside a workspace 103,179 (6%)",
        "agent      claude 1,300,000 (76%)   codex 403,179 (24%)",
        "model      claude-sonnet-5 1,200,000 (70%)   gpt-5.6 403,179 (24%)   claude-haiku-4-5 100,000 (6%)",
        "",
      ].join("\n"));
      expect(run.stdout).not.toContain("sf_1");
      expect(run.stdout).not.toContain("ws_");

      // No usable name lookup (the default fake cmux-tui echoes its arguments): ids are
      // never printed, so the workspace line is dropped and the other lines stay.
      const noNames = runShim(["coderouter", "usage"], USAGE_ENV, usageCurl(JSON.stringify(body)));
      expect(noNames.stdout).not.toContain("workspace");
      expect(noNames.stdout).not.toContain("ws_");
      expect(noNames.stdout).toContain("agent    claude 1,300,000 (76%)   codex 403,179 (24%)");
      const json = runShim(["coderouter", "usage", "--json"], USAGE_ENV, usageCurl(JSON.stringify(body)));
      expect(JSON.parse(json.stdout).terminals).toEqual(body.terminals);

      // Six or more entries: the top five, then a count of the rest.
      const many = { ...USAGE, models: Array.from({ length: 7 }, (_, i) => ({ model: `m${i}`, totals: totals(70_000 - i * 10_000) })) };
      const long = runShim(["coderouter", "usage"], USAGE_ENV, usageCurl(JSON.stringify(many)));
      expect(long.stdout).toContain("model    m0 70,000 (4%)   m1 60,000 (4%)   m2 50,000 (3%)   m3 40,000 (2%)   m4 30,000 (2%)   +2 more");
    });

    test("usage names an unnamed machine by id, and explains a $0 cost on real tokens as unpriced", () => {
      const body = { ...USAGE, displayName: null, totals: { ...USAGE.totals, apiEquivalentUsd: 0 } };
      const run = runShim(["coderouter", "usage"], USAGE_ENV, usageCurl(JSON.stringify(body)));
      expect(run.status).toBe(0);
      expect(run.stdout).toContain("CodeRouter usage for 28e987ce-549f-4040-8489-5ed3789faf3e, last 30 days");
      expect(run.stdout).toContain("machine  28e987ce-549f-4040-8489-5ed3789faf3e\n");
      expect(run.stdout).toContain("cost     $0.00 API-equivalent  (no price on record for the models used)\n");
    });

    test("usage --days limits the day table and --tsv prints the raw day table with zeros", () => {
      const week = runShim(["coderouter", "usage", "--days", "7"], USAGE_ENV, usageCurl(USAGE_BODY));
      expect(week.status).toBe(0);
      expect(week.stdout).not.toContain("2026-09-02");
      expect(week.stdout).toContain("Days without usage are not listed (5 of 7).");
      const tsv = runShim(["coderouter", "usage", "--tsv", "--days=3"], USAGE_ENV, usageCurl(USAGE_BODY));
      expect(tsv.status).toBe(0);
      expect(tsv.stdout).toBe("day\ttokens\tapi_equivalent_usd\n2026-09-08\t0\t0\n2026-09-09\t1234567\t12.3456\n2026-09-10\t68612\t0.004\n");
      for (const bad of ["99", "0", "x", ""]) {
        const run = runShim(["coderouter", "usage", "--days", bad], USAGE_ENV, usageCurl(USAGE_BODY));
        expect(run.status).toBe(2);
        expect(run.stderr).toContain(`--days needs a number from 1 to 30, got '${bad}'`);
      }
    });

    test("usage --json and CMUX_OUTPUT=json return the vm-usage contract unchanged, for agents and scripts", () => {
      const run = runShim(["coderouter", "usage", "--json"], USAGE_ENV, usageCurl(USAGE_BODY));
      expect(run.status).toBe(0);
      expect(JSON.parse(run.stdout)).toEqual(USAGE);
      const env = runShim(["coderouter", "machines"], { ...USAGE_ENV, CMUX_OUTPUT: "json" }, usageCurl(USAGE_BODY));
      expect(JSON.parse(env.stdout)).toEqual(USAGE);
    });

    test("usage exits 3 when the ledger is unavailable (text and json), and says so when the machine spent nothing", () => {
      const unavailableBody = JSON.stringify({ vmId: "vm-a", displayName: null, periodDays: 30, kind: "unavailable", asOf: null, totals: null, days: [] });
      const unavailable = runShim(["coderouter", "usage"], USAGE_ENV, usageCurl(unavailableBody));
      expect(unavailable.status).toBe(3);
      expect(unavailable.stdout).toBe("CodeRouter usage is unavailable right now (the usage ledger did not answer). Retry in a moment.\n");
      const json = runShim(["coderouter", "usage", "--json"], USAGE_ENV, usageCurl(unavailableBody));
      expect(json.status).toBe(3);
      expect(JSON.parse(json.stdout).kind).toBe("unavailable");

      const zero = runShim(
        ["coderouter", "usage"],
        USAGE_ENV,
        usageCurl(JSON.stringify({
          vmId: "vm-zero",
          displayName: null,
          periodDays: 30,
          kind: "ready",
          asOf: "2026-09-10T00:00:00.000Z",
          totals: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, totalTokens: 0, apiEquivalentUsd: 0 },
          days: [{ day: "2026-09-10", totalTokens: 0, apiEquivalentUsd: 0 }],
        })),
      );
      expect(zero.status).toBe(0);
      expect(zero.stdout).toContain("machine  vm-zero\n");
      expect(zero.stdout).toContain("\nNo CodeRouter usage from this machine in the last 30 days.\n");
      expect(zero.stdout).not.toContain("day  ");
      expect(zero.stdout).not.toContain("trend");
    });

    test("usage passes through bodies it cannot format (not JSON, an error body, a non-numeric field) and rejects unknown options", () => {
      const raw = runShim(["coderouter", "usage"], USAGE_ENV, usageCurl("not json"));
      expect(raw.status).toBe(0);
      expect(raw.stdout).toBe("not json\n");
      const errorBody = runShim(["coderouter", "usage"], USAGE_ENV, usageCurl(JSON.stringify({ error: "vm_not_found" })));
      expect(errorBody.status).toBe(0);
      expect(JSON.parse(errorBody.stdout)).toEqual({ error: "vm_not_found" });
      for (const mutate of [
        (body: Record<string, unknown>) => { (body.totals as Record<string, unknown>).totalTokens = "68612"; },
        (body: Record<string, unknown>) => { body.periodDays = "30 days"; },
        (body: Record<string, unknown>) => { body.asOf = null; },
      ]) {
        const malformed = JSON.parse(USAGE_BODY);
        mutate(malformed);
        const passthrough = runShim(["coderouter", "usage"], USAGE_ENV, usageCurl(JSON.stringify(malformed)));
        expect(passthrough.status).toBe(0);
        expect(JSON.parse(passthrough.stdout)).toEqual(malformed);
      }
      const bad = runShim(["coderouter", "usage", "--tsv2"], USAGE_ENV, usageCurl(USAGE_BODY));
      expect(bad.status).toBe(2);
      expect(bad.stderr).toContain("coderouter usage: unknown option --tsv2");
    });

    test("usage --help documents the modes, the stable lines, and the exit codes", () => {
      const help = runShim(["coderouter", "usage", "--help"]);
      expect(help.status).toBe(0);
      expect(help.stdout).toContain("cmux coderouter usage [--json|--tsv] [--days <n>]");
      expect(help.stdout).toContain("Exit codes: 0 usage shown, 1 the edge did not answer, 2 bad option, 3 usage ledger unavailable.");
      const ja = runShim(["coderouter", "usage", "-h"], { LANG: "ja_JP.UTF-8" });
      expect(ja.stdout).toContain("終了コード");
    });

    test("reads models through the configured HTTPS edge", () => {
      const models = runShim(
        ["coderouter", "models"],
        USAGE_ENV,
        (directory) => {
          const curl = join(directory, "curl");
          writeFileSync(curl, "#!/bin/sh\nprintf '%s' '{\"data\":[{\"id\":\"test-model\"}]}'\n");
          chmodSync(curl, 0o755);
        },
      );
      expect(models.status).toBe(0);
      expect(JSON.parse(models.stdout).data[0].id).toBe("test-model");
    });

    test("maps a bare prompt through the short agent alias", () => {
      const run = runShim(["agent", "claude", "reply exactly pong"], {}, (directory) => {
        const claude = join(directory, "claude");
        writeFileSync(claude, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
        chmodSync(claude, 0o755);
      });
      expect(run.status).toBe(0);
      expect(run.stdout.trim().split("\n")).toEqual(["-p", "reply exactly pong"]);
    });

    test("accepts the canonical separator before a guest prompt", () => {
      const run = runShim(["coderouter", "agent", "codex", "--", "reply exactly pong"], {}, (directory) => {
        const codex = join(directory, "codex");
        writeFileSync(codex, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
        chmodSync(codex, 0o755);
      });
      expect(run.status).toBe(0);
      expect(run.stdout.trim().split("\n")).toEqual(["exec", "reply exactly pong"]);
    });

    test("keeps cmux-tui's local agent scope available", () => {
      const run = runShim(["agent", "list"]);
      expect(run.status).toBe(0);
      expect(run.argv).toEqual(["--session", "cloud", "agent", "list"]);
    });

    test("passes provider subcommands through the coderouter prefix", () => {
      const run = runShim(["coderouter", "agent", "codex", "exec", "summarize"], {}, (directory) => {
        const codex = join(directory, "codex");
        writeFileSync(codex, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
        chmodSync(codex, 0o755);
      });
      expect(run.status).toBe(0);
      expect(run.stdout.trim().split("\n")).toEqual(["exec", "summarize"]);
    });

    test("keeps account login host-owned", () => {
      const run = runShim(["coderouter", "claude", "list"]);
      expect(run.status).toBe(2);
      expect(run.stderr).toContain("host-owned");
      expect(run.stderr).toContain("Stack tokens");
    });
  });

  // `cmux notify` is what agent hooks run inside a machine. cmux-tui's own
  // `notify` verb carries the macOS signature (subtitle field, scoped --clear,
  // --reply refused, selectors validated), so the shim forwards the arguments
  // untouched on the machine's session. A translation here would fork the
  // grammar: https://github.com/manaflow-ai/cmux/pull/12131 moved it into the
  // daemon and the daemon's tests pin it.
  describe("notify", () => {
    test("forwards every argument verbatim to the daemon's notify verb on the local session", () => {
      const run = runShim(
        ["notify", "--title", "Build done", "--subtitle", "api", "--body", "3 tests passed", "--surface", "current"],
        { CMUX_TUI_TERMINAL_ID: TERMINAL_ID },
      );
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      expect(run.argv).toEqual([
        "--session",
        "cloud",
        "--quiet",
        "notify",
        "--title",
        "Build done",
        "--subtitle",
        "api",
        "--body",
        "3 tests passed",
        "--surface",
        "current",
      ]);
    });

    test("does not fold, drop, or rewrite flags: --clear and --reply reach the daemon for it to decide", () => {
      const clear = runShim(["notify", "--clear", "--workspace", "current"], { CMUX_TUI_TERMINAL_ID: TERMINAL_ID });
      expect(clear.status).toBe(0);
      expect(clear.argv).toEqual(["--session", "cloud", "--quiet", "notify", "--clear", "--workspace", "current"]);
      const reply = runShim(["notify", "--title=T", "--reply"], { CMUX_TUI_TERMINAL_ID: undefined });
      expect(reply.argv).toEqual(["--session", "cloud", "--quiet", "notify", "--title=T", "--reply"]);
    });

    test("drops --quiet when the caller wants the JSON result, since the two output modes exclude each other", () => {
      const json = runShim(["notify", "--title", "T", "--json"], { CMUX_TUI_TERMINAL_ID: TERMINAL_ID });
      expect(json.argv).toEqual(["--session", "cloud", "notify", "--title", "T", "--json"]);
      const jsonl = runShim(["notify", "--jsonl", "--title=T"], {});
      expect(jsonl.argv).toEqual(["--session", "cloud", "notify", "--jsonl", "--title=T"]);
    });

    test("keeps --quiet when a body value merely contains a JSON flag", () => {
      const run = runShim(["notify", "--body", "status --json complete"]);
      expect(run.argv).toEqual(["--session", "cloud", "--quiet", "notify", "--body", "status --json complete"]);
    });

    test("never adds Mac socket identity from the environment", () => {
      const run = runShim(["notify", "--title", "T"], {
        CMUX_TUI_TERMINAL_ID: TERMINAL_ID,
        CMUX_SOCKET_PATH: "/tmp/should-not-leak.sock",
        CMUX_WORKSPACE_ID: "11111111-1111-1111-1111-111111111111",
        CMUX_SURFACE_ID: "22222222-2222-2222-2222-222222222222",
      });
      expect(run.status).toBe(0);
      expect(run.argv).toEqual(["--session", "cloud", "--quiet", "notify", "--title", "T"]);
    });
  });

  test("finds the daemon binary under the daemon's home when CMUX_TUI_BIN is unset", () => {
    // The root layout keeps the binary at /root/.cmux/bin; layout-aware bakes
    // symlink /usr/local/bin/cmux-tui. A dev Mac with either would shadow the
    // per-test fake, so only assert when neither exists on this host.
    const shadowed = ["/usr/local/bin/cmux-tui", "/root/.cmux/bin/cmux-tui"].some((path) => {
      try {
        return spawnSync("test", ["-x", path]).status === 0;
      } catch {
        return false;
      }
    });
    if (shadowed) return;
    const dir = mkdtempSync(join(tmpdir(), "cmux-guest-cli-home-"));
    const shim = join(dir, "cmux");
    writeFileSync(shim, GUEST_CMUX_SHIM);
    chmodSync(shim, 0o755);
    const binDir = join(dir, ".cmux", "bin");
    spawnSync("mkdir", ["-p", binDir]);
    const fakeTui = join(binDir, "cmux-tui");
    writeFileSync(fakeTui, '#!/bin/sh\nprintf \'home-fake\'; printf \' %s\' "$@"; echo\n');
    chmodSync(fakeTui, 0o755);
    const result = spawnSync("sh", [shim, "notify", "--title", "T"], {
      encoding: "utf8",
      env: { NODE_ENV: "test", PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: dir, CMUX_TUI_TERMINAL_ID: TERMINAL_ID },
    });
    expect(result.stderr).toBe("");
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("home-fake --session cloud --quiet notify --title T");
  }, 20_000);

  test("install command is a safe atomic base64 write", () => {
    const command = guestCliInstallCommand();
    expect(command).toContain(`${GUEST_CMUX_SHIM_PATH}.tmp`);
    expect(command).toContain(`mv ${GUEST_CMUX_SHIM_PATH}.tmp ${GUEST_CMUX_SHIM_PATH}`);
    expect(command).toContain("chmod 0755");
    // The payload is base64: no shell metacharacters from the script body leak
    // into the exec command line.
    const encoded = command.match(/printf '%s' '([A-Za-z0-9+/=]+)'/);
    expect(encoded).not.toBeNull();
    expect(Buffer.from(encoded![1], "base64").toString("utf8")).toBe(GUEST_CMUX_SHIM);
  });
});

// ---------------------------------------------------------------------------
// Agent primitives shared with the Mac CLI: layout export/apply, env, the
// Mac-flavoured terminal verbs, and their peer forms. A stateful fake
// cmux-tui logs every argv (one call per `--END--`-terminated block) and
// answers creation verbs with CreatedTerminalPath / CreatedBrowserPath results
// whose ids embed the call number, so the exact op sequence is assertable.
// ---------------------------------------------------------------------------

const STATEFUL_FAKE_TUI = `#!/bin/sh
{ printf '%s\\n' "$@"; printf '%s\\n' "--END--"; } >> "$FAKE_LOG"
n=$(cat "$FAKE_STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$FAKE_STATE"
while [ $# -gt 0 ]; do
  case "$1" in
    --session|--socket) shift 2 ;;
    --json|--quiet|--jsonl) shift ;;
    *) break ;;
  esac
done
a="\${1:-}"; b="\${2:-}"; c="\${3:-}"; d="\${4:-}"
if [ "$a" = session ] && [ "$c" = snapshot ]; then cat "$FAKE_SNAPSHOT"; exit 0; fi
if [ "$a" = workspace ] && [ "$b" = create ]; then
  case "$*" in
    *--empty*)
      if [ "\${FAKE_NO_EMPTY:-0}" = 1 ]; then printf '{"error":{"code":"usage.invalid","message":"unknown flag --empty"}}\\n'; exit 2; fi
      printf '{"value":{"kind":"workspace","workspace_id":"ws_new%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$n" "$n" ;;
    *) printf '{"value":{"kind":"terminal","workspace_id":"ws_new%s","screen_id":"screen_%s","pane_id":"pane_%s","tab_id":"tab_%s","terminal_id":"term_%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$n" "$n" "$n" "$n" "$n" "$n" ;;
  esac
  exit 0
fi
if [ "$a" = workspace ] && [ "$b" = current ] && [ "$c" = show ]; then [ "\${FAKE_NO_CURRENT:-0}" = 1 ] && exit 1; printf '{"id":"ws_cur"}\\n'; exit 0; fi
if [ "$a" = workspace ] && [ "$c" = run ]; then printf '{"value":{"kind":"terminal","workspace_id":"%s","screen_id":"screen_%s","pane_id":"pane_%s","tab_id":"tab_%s","terminal_id":"term_%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n" "$n" "$n" "$n" "$n"; exit 0; fi
if [ "$a" = pane ] && [ "$c" = split ]; then printf '{"value":{"kind":"terminal","workspace_id":"ws_x","screen_id":"screen_1","pane_id":"pane_%s","tab_id":"tab_%s","terminal_id":"term_%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$n" "$n" "$n" "$n"; exit 0; fi
if [ "$a" = pane ] && [ "$c" = run ]; then printf '{"value":{"kind":"terminal","workspace_id":"ws_x","screen_id":"screen_1","pane_id":"%s","tab_id":"tab_%s","terminal_id":"term_%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n" "$n" "$n"; exit 0; fi
if [ "$a" = pane ] && [ "$c" = tab ] && [ "$d" = create ]; then
  if [ "\${FAKE_NO_BROWSER:-0}" = 1 ]; then printf '{"error":{"code":"browser.unavailable","message":"no browser runtime"}}\\n'; exit 1; fi
  printf '{"value":{"kind":"browser","workspace_id":"ws_x","screen_id":"screen_1","pane_id":"%s","tab_id":"tab_%s","browser_id":"browser_%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n" "$n" "$n"; exit 0
fi
if [ "$a" = terminal ] && [ "$c" = screen ] && [ "$d" = wait ]; then
  case "$*" in
    *CMUX-FILE-\\(OK*) printf '{"matched":true,"text":"CMUX-FILE-READY\\\\nCMUX-FILE-OK bytes=%s path=%s mode=%s\\\\n"}\\n' "\${FAKE_FILE_BYTES:-11}" "\${FAKE_FILE_PATH:-/root/app/.env}" "\${FAKE_FILE_MODE:-640}"; exit 0 ;;
    *CMUX-FILE-READY*)
      if [ "\${FAKE_FILE_REFUSE:-0}" = 1 ]; then printf '{"matched":false,"text":"CMUX-FILE-ERR is-directory /root/app\\\\n"}\\n'; exit 0; fi
      printf '{"matched":%s,"text":"CMUX-FILE-READY\\\\n"}\\n' "\${FAKE_MATCHED:-true}"; exit 0 ;;
    *CMUX-ENV-\\(OK*) printf '{"matched":true,"text":"CMUX-ENV-READY\\\\nCMUX-ENV-OK keys=2 path=/root/.config/cmux/env\\\\n"}\\n'; exit 0 ;;
    *CMUX-ENV-READY*) printf '{"matched":%s,"text":"CMUX-ENV-READY\\\\n"}\\n' "\${FAKE_MATCHED:-true}"; exit 0 ;;
  esac
  printf '{"matched":%s,"text":"λ "}\\n' "\${FAKE_MATCHED:-true}"; exit 0
fi
if [ "$a" = terminal ] && [ "$c" = screen ] && [ "$d" = read ]; then printf '{"cols":80,"rows":24,"text":"hello screen"}\\n'; exit 0; fi
if [ "$a" = terminal ] && [ "$c" = process ] && [ "$d" = wait ]; then
  if [ "\${FAKE_EXIT_PENDING:-0}" = 1 ] || [ "$n" -lt "\${FAKE_EXIT_PENDING_UNTIL:-0}" ]; then printf '{"value":{"terminal_id":"%s","state":"pending"},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n"; exit 0; fi
  case "\${FAKE_EXIT_KIND:-exit}" in
    signal) printf '{"value":{"terminal_id":"%s","state":"exited","outcome":{"kind":"signal","signal":9,"core_dumped":false}},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n" ;;
    *) printf '{"value":{"terminal_id":"%s","state":"exited","outcome":{"kind":"exit","code":3}},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n" ;;
  esac
  exit 0
fi
if [ "$a" = terminal ] && [ "$c" = output ] && [ "$d" = read ]; then
  if [ "\${FAKE_OUTPUT_PAGED:-0}" = 1 ]; then
    case "$*" in
      *"--after 0"*) printf '{"value":{"terminal_id":"%s","text":"line one\\\\n","start_offset":0,"next_offset":9,"complete":false},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n"; exit 0 ;;
      *) printf '{"value":{"terminal_id":"%s","text":"line two\\\\n","start_offset":9,"next_offset":18,"complete":true},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n"; exit 0 ;;
    esac
  fi
  printf '{"value":{"terminal_id":"%s","text":"line one\\\\nline two\\\\n","start_offset":0,"next_offset":18,"complete":true},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n"; exit 0; fi
if [ "$a" = remote ] && [ "$b" = connect ]; then printf '{"event":"connection-snapshot","local_socket":"%s"}\\n' "\${FAKE_LINK_SOCKET:-}"; exit 0; fi
printf '{}\\n'
`;

/** A daemon snapshot: ws_main is a 0.6 horizontal split whose right half is a 0.3 vertical split over a 2-pane stack. */
const SNAPSHOT_FIXTURE = {
  workspaces: [
    { id: "ws_main", name: "main", index: 0, focused: true },
    { id: "ws_api", name: "api", index: 1, focused: false },
    { id: "ws_empty", name: "empty", index: 2, focused: false },
    { id: "ws_dup1", name: "dup", index: 3, focused: false },
    { id: "ws_dup2", name: "dup", index: 4, focused: false },
  ],
  screens: [
    {
      id: "screen_1",
      workspace_id: "ws_main",
      name: null,
      index: 0,
      focused: true,
      layout: {
        version: 1,
        screen_id: "screen_1",
        active_pane_id: "pane_1",
        zoomed_pane_id: null,
        root: {
          kind: "split",
          split_id: "split_1",
          direction: "horizontal",
          ratio: 0.6,
          first: { kind: "leaf", pane_id: "pane_1", tab_ids: ["tab_1", "tab_2"], active_tab_id: "tab_1" },
          second: {
            kind: "split",
            split_id: "split_2",
            direction: "vertical",
            ratio: 0.3,
            first: { kind: "leaf", pane_id: "pane_2", tab_ids: ["tab_3"] },
            second: { kind: "stack", pane_ids: ["pane_3", "pane_4"], expanded_pane_id: "pane_3" },
          },
        },
      },
    },
    {
      id: "screen_2",
      workspace_id: "ws_api",
      name: null,
      index: 0,
      focused: true,
      layout: { version: 1, screen_id: "screen_2", active_pane_id: "pane_5", zoomed_pane_id: null, root: { kind: "leaf", pane_id: "pane_5", tab_ids: ["tab_5"] } },
    },
  ],
  panes: [
    { id: "pane_1", screen_id: "screen_1", name: null, focused: true, zoomed: false },
    { id: "pane_2", screen_id: "screen_1", name: null, focused: false, zoomed: false },
    { id: "pane_3", screen_id: "screen_1", name: null, focused: false, zoomed: false },
    { id: "pane_4", screen_id: "screen_1", name: null, focused: false, zoomed: false },
    { id: "pane_5", screen_id: "screen_2", name: null, focused: true, zoomed: false },
  ],
  // tab_2 is listed before tab_1 on purpose: export must order tabs by index, not wire order.
  tabs: [
    { id: "tab_2", pane_id: "pane_1", name: null, index: 1, focused: false, content_kind: "browser", content_id: "browser_1" },
    { id: "tab_1", pane_id: "pane_1", name: "agent", index: 0, focused: true, content_kind: "terminal", content_id: "term_agent" },
    { id: "tab_3", pane_id: "pane_2", name: "tests", index: 0, focused: true, content_kind: "terminal", content_id: "term_tests" },
    { id: "tab_4a", pane_id: "pane_3", name: null, index: 0, focused: true, content_kind: "terminal", content_id: "term_logs" },
    { id: "tab_4b", pane_id: "pane_4", name: null, index: 0, focused: true, content_kind: "terminal", content_id: "term_shell" },
    { id: "tab_5", pane_id: "pane_5", name: null, index: 0, focused: true, content_kind: "terminal", content_id: "term_api" },
  ],
  terminals: [
    { id: "term_agent", tab_id: "tab_1", tab_ids: ["tab_1"], title: "claude", cwd: "/root/work/app", cols: 80, rows: 24, running: true, lifecycle: "running" },
    { id: "term_tests", tab_id: "tab_3", tab_ids: ["tab_3"], title: "bun", cwd: "/root/work/app", cols: 80, rows: 24, running: true, lifecycle: "running" },
    { id: "term_logs", tab_id: "tab_4a", tab_ids: ["tab_4a"], title: "tail", cwd: "/var/log", cols: 80, rows: 24, running: true, lifecycle: "running" },
    { id: "term_shell", tab_id: "tab_4b", tab_ids: ["tab_4b"], title: "bash", cols: 80, rows: 24, running: true, lifecycle: "running" },
    { id: "term_api", tab_id: "tab_5", tab_ids: ["tab_5"], title: "bash", cwd: "/root/work/api", cols: 80, rows: 24, running: true, lifecycle: "running" },
  ],
  browsers: [{ id: "browser_1", tab_id: "tab_2", url: "http://localhost:3000", title: "app", status: "ready" }],
  agents: [],
};

const LAYOUT_DOC = {
  name: "dev",
  cwd: "work/app",
  env: { NODE_ENV: "development" },
  layout: {
    direction: "horizontal",
    split: 0.6,
    children: [
      { pane: { surfaces: [{ type: "terminal", name: "agent", command: "claude" }, { type: "browser", url: "http://localhost:3000", name: "app" }] } },
      {
        direction: "vertical",
        split: 0.3,
        children: [
          { pane: { surfaces: [{ type: "terminal", name: "tests", command: "bun test --watch", env: { CI: "1" } }] } },
          { pane: { surfaces: [{ type: "terminal", cwd: "/var/log", focus: true }] } },
        ],
      },
    ],
  },
};

const PROMPT_WAIT = ["screen", "wait", "--pattern", "λ|\\$ $|# $", "--timeout-ms", "8000"];

type StatefulRun = { calls: string[][]; status: number | null; stdout: string; stderr: string; home: string };

function makeStatefulDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "cmux-guest-prims-"));
  writeFileSync(join(dir, "cmux"), GUEST_CMUX_SHIM);
  chmodSync(join(dir, "cmux"), 0o755);
  writeFileSync(join(dir, "cmux-tui"), STATEFUL_FAKE_TUI);
  chmodSync(join(dir, "cmux-tui"), 0o755);
  writeFileSync(join(dir, "snapshot.json"), JSON.stringify(SNAPSHOT_FIXTURE));
  return dir;
}

/** Runs the shim in `dir` (HOME) against the stateful fake and returns every daemon call. */
function runStateful(dir: string, args: string[], env: Record<string, string | undefined> = {}, input?: string, shell = "sh"): StatefulRun {
  const log = join(dir, "calls.log");
  writeFileSync(log, "");
  writeFileSync(join(dir, "state"), "");
  const result = spawnSync(shell, [join(dir, "cmux"), ...args], {
    encoding: "utf8",
    timeout: 20_000,
    input,
    env: {
      NODE_ENV: "test",
      HOME: dir,
      CMUX_TUI_BIN: join(dir, "cmux-tui"),
      FAKE_LOG: log,
      FAKE_STATE: join(dir, "state"),
      FAKE_SNAPSHOT: join(dir, "snapshot.json"),
      PATH: `${dir}:${process.env.PATH ?? "/usr/bin:/bin"}`,
      ...env,
    },
  });
  const calls: string[][] = [];
  let current: string[] = [];
  for (const line of readFileSync(log, "utf8").split("\n")) {
    if (line === "--END--") {
      calls.push(current);
      current = [];
    } else if (line !== "" || current.length > 0) {
      current.push(line);
    }
  }
  return { calls, status: result.status, stdout: result.stdout, stderr: result.stderr, home: dir };
}

/** Argv with the routing prefix (`--session cloud` / `--socket …`) removed. */
const stripRoute = (call: string[]) => call.slice(2);

describe("in-VM cmux shim: agent primitives", () => {
  test("is valid for dash too when it is installed (the image's /bin/sh is dash)", () => {
    if (!existsSync("/bin/dash")) return;
    const result = spawnSync("/bin/dash", ["-n"], { input: GUEST_CMUX_SHIM, encoding: "utf8" });
    expect(result.stderr).toBe("");
    expect(result.status).toBe(0);
  });

  test("help lists the layout, env, terminal, and peer verbs", () => {
    const run = runShim(["--help"]);
    expect(run.status).toBe(0);
    for (const line of [
      "cmux layout export [--workspace <ws>] [--raw]",
      "cmux layout apply [--workspace <ws>|--name <n>] [--cwd <dir>] [<file>|-]",
      "cmux env set|ls|rm|path",
      "cmux send [--terminal <id>] <text>",
      "cmux send-key [--terminal <id>] <key> [key...]",
      "cmux read-screen [--terminal <id>] [--json]",
      "cmux terminal send|read|wait|wait-exit|output|close <id>",
      "cmux vm terminal send|read|wait|wait-exit|output|close <machine> <term>",
      "cmux vm workspace new|rename|close|rm <machine>",
      "cmux vm agent <machine> --agent <claude|codex|opencode|pi>",
      "cmux vm layout export|apply <machine>",
      "cmux vm env set|ls|rm|path <machine>",
      "cmux self [--json]",
      "cmux vm ls [--json]",
      "cmux file receive <path> [--mode <octal>]",
      "cmux vm push <machine> <local-file> <remote-path> [--mode <octal>]",
      "cmux vm agent <machine> --agent <claude|codex|opencode|pi> [--wait [--output] [--timeout <s>]] -- <prompt>",
      "cmux agent <claude|codex|opencode|pi> [--timeout <s>] [args...]",
    ]) {
      expect(run.stdout).toContain(line);
    }
    const fileHelp = runShim(["file", "help"]);
    expect(fileHelp.status).toBe(0);
    for (const line of ["cmux file receive <path> [--mode <octal>]", "CMUX-FILE-READY", "CMUX-FILE-OK bytes=<n> path=<p> mode=<m>", "CMUX-FILE-ERR <reason>", "cmux vm push <machine> <local-file> <remote-path>"]) {
      expect(fileHelp.stdout).toContain(line);
    }
    expect(runShim(["file", "help"], { LANG: "ja_JP.UTF-8" }).stdout).toContain("CMUX-FILE-READY");
    const envHelp = runShim(["env", "help"]);
    for (const line of ["cmux env receive [--stdin]", "CMUX-ENV-READY / CMUX-ENV-OK / CMUX-ENV-ERR", "cmux env set -"]) {
      expect(envHelp.stdout).toContain(line);
    }
    for (const line of [
      "cmux env set|ls|rm|path",
    ]) {
      expect(run.stdout).toContain(line);
    }
    const vmHelp = runShim(["vm", "help"]);
    expect(vmHelp.stdout).toContain("cmux vm agent <machine> --agent");
    expect(vmHelp.stdout).toContain("[--wait [--output] [--timeout <s>]]");
    expect(vmHelp.stdout).toContain("cmux vm env set|ls|rm|path <machine>");
    expect(vmHelp.stdout).toContain("cmux vm push <machine> <local-file> <remote-path> [--mode <octal>]");
  });

  describe("local Mac-flavoured verbs", () => {
    test("send defaults to the caller's terminal, --terminal overrides, nothing else is an error", () => {
      const dir = makeStatefulDir();
      const mine = runStateful(dir, ["send", "hi", "there"], { CMUX_TUI_TERMINAL_ID: TERMINAL_ID });
      expect(mine.status).toBe(0);
      expect(mine.calls).toEqual([["--session", "cloud", "terminal", TERMINAL_ID, "write", "--text", "hi there"]]);

      const other = runStateful(dir, ["send", "--terminal", "term_other", "ls -la"], { CMUX_TUI_TERMINAL_ID: TERMINAL_ID });
      expect(other.calls).toEqual([["--session", "cloud", "terminal", "term_other", "write", "--text", "ls -la"]]);

      const none = runStateful(dir, ["send", "hi"], { CMUX_TUI_TERMINAL_ID: undefined });
      expect(none.status).toBe(2);
      expect(none.stderr).toContain("--terminal <term_id>");
      expect(none.calls).toEqual([]);
    });

    test("send-key and read-screen map to keys and screen read", () => {
      const dir = makeStatefulDir();
      const keys = runStateful(dir, ["send-key", "ctrl+c", "enter"], { CMUX_TUI_TERMINAL_ID: TERMINAL_ID });
      expect(keys.calls).toEqual([["--session", "cloud", "terminal", TERMINAL_ID, "keys", "ctrl+c", "enter"]]);
      const screen = runStateful(dir, ["read-screen", "--terminal", "term_2", "--json"]);
      expect(screen.status).toBe(0);
      expect(screen.calls).toEqual([["--session", "cloud", "--json", "terminal", "term_2", "screen", "read"]]);
      expect(JSON.parse(screen.stdout).text).toBe("hello screen");
    });

    test("terminal send types text first, then the comma-separated keys; `--` makes the rest literal", () => {
      const dir = makeStatefulDir();
      const run = runStateful(dir, ["terminal", "send", "term_1", "bun", "test", "--keys", "enter,ctrl+c", "--", "--json"]);
      expect(run.status).toBe(0);
      expect(run.calls.map(stripRoute)).toEqual([
        ["terminal", "term_1", "write", "--text", "bun test --json"],
        ["terminal", "term_1", "keys", "enter", "ctrl+c"],
      ]);
      const keysOnly = runStateful(dir, ["terminal", "send", "term_1", "--keys", "enter"]);
      expect(keysOnly.calls.map(stripRoute)).toEqual([["terminal", "term_1", "keys", "enter"]]);
      const nothing = runStateful(dir, ["terminal", "send", "term_1"]);
      expect(nothing.status).toBe(2);
      expect(nothing.calls).toEqual([]);
    });

    test("terminal read/wait/close; wait converts seconds to ms and exits 1 when the screen never matches", () => {
      const dir = makeStatefulDir();
      const read = runStateful(dir, ["terminal", "read", "term_9"]);
      expect(read.calls.map(stripRoute)).toEqual([["terminal", "term_9", "screen", "read"]]);
      const wait = runStateful(dir, ["terminal", "wait", "term_1", "--pattern", "pass|fail", "--timeout", "2.5"]);
      expect(wait.status).toBe(0);
      expect(wait.stdout).toContain("OK matched /pass|fail/ on term_1");
      expect(wait.calls).toEqual([["--session", "cloud", "--json", "terminal", "term_1", "screen", "wait", "--pattern", "pass|fail", "--timeout-ms", "2500"]]);
      const missed = runStateful(dir, ["terminal", "wait", "term_1", "--pattern", "pass"], { FAKE_MATCHED: "false" });
      expect(missed.status).toBe(1);
      expect(missed.stderr).toContain("timed out after 30s");
      expect(missed.calls[0]).toContain("30000");
      const noPattern = runStateful(dir, ["terminal", "wait", "term_1"]);
      expect(noPattern.status).toBe(2);
      const close = runStateful(dir, ["terminal", "close", "term_1"]);
      expect(close.calls.map(stripRoute)).toEqual([["terminal", "term_1", "close"]]);
    });

    test("cmux-tui's own id-first terminal grammar still passes through untouched", () => {
      const dir = makeStatefulDir();
      expect(runStateful(dir, ["terminal", "term_x", "keys", "enter"]).calls).toEqual([["--session", "cloud", "terminal", "term_x", "keys", "enter"]]);
      expect(runStateful(dir, ["terminal", "list"]).calls).toEqual([["--session", "cloud", "terminal", "list"]]);
    });

    test("new-workspace, tree, and new-split (from the caller's pane, else the focused pane; right/down only)", () => {
      const dir = makeStatefulDir();
      expect(runStateful(dir, ["new-workspace", "--name", "t"]).calls).toEqual([["--session", "cloud", "workspace", "create", "--name", "t"]]);
      expect(runStateful(dir, ["new-workspace"]).calls).toEqual([["--session", "cloud", "workspace", "create"]]);
      const tree = runStateful(dir, ["tree", "--json"]);
      expect(tree.calls).toEqual([["--session", "cloud", "--json", "session", "current", "snapshot"]]);
      expect(JSON.parse(tree.stdout).workspaces[0].id).toBe("ws_main");

      const fromCaller = runStateful(dir, ["new-split", "down"], { CMUX_TUI_TERMINAL_ID: "term_logs" });
      expect(fromCaller.status).toBe(0);
      expect(fromCaller.calls.map(stripRoute)).toEqual([["--json", "session", "current", "snapshot"], ["pane", "pane_3", "split", "--down"]]);
      const focused = runStateful(dir, ["new-split", "right"], { CMUX_TUI_TERMINAL_ID: undefined });
      expect(focused.status).toBe(0);
      expect(focused.calls.at(-1)).toEqual(["--session", "cloud", "pane", "pane_1", "split", "--right"]);
      const explicit = runStateful(dir, ["new-split", "right", "--pane", "pane_9"]);
      expect(explicit.calls).toEqual([["--session", "cloud", "pane", "pane_9", "split", "--right"]]);
      const left = runStateful(dir, ["new-split", "left"]);
      expect(left.status).toBe(2);
      expect(left.stderr).toContain("right or down");
    });
  });

  describe("layout export", () => {
    test("turns the focused workspace's LayoutDocument into the declarative document (tabs by index, stack → vertical splits)", () => {
      const dir = makeStatefulDir();
      const run = runStateful(dir, ["layout", "export"]);
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      expect(run.calls).toEqual([["--session", "cloud", "--json", "session", "current", "snapshot"]]);
      expect(JSON.parse(run.stdout)).toEqual({
        name: "main",
        cwd: dir,
        layout: {
          direction: "horizontal",
          split: 0.6,
          children: [
            { pane: { surfaces: [{ type: "terminal", name: "agent", cwd: "/root/work/app" }, { type: "browser", url: "http://localhost:3000" }] } },
            {
              direction: "vertical",
              split: 0.3,
              children: [
                { pane: { surfaces: [{ type: "terminal", name: "tests", cwd: "/root/work/app" }] } },
                {
                  direction: "vertical",
                  split: 0.5,
                  children: [{ pane: { surfaces: [{ type: "terminal", cwd: "/var/log" }] } }, { pane: { surfaces: [{ type: "terminal" }] } }],
                },
              ],
            },
          ],
        },
      });
    });

    test("selects by id or unique name, refuses ambiguous names, and --raw prints the daemon document", () => {
      const dir = makeStatefulDir();
      const api = runStateful(dir, ["layout", "export", "--workspace", "api"]);
      expect(api.status).toBe(0);
      expect(JSON.parse(api.stdout)).toEqual({ name: "api", cwd: dir, layout: { pane: { surfaces: [{ type: "terminal", cwd: "/root/work/api" }] } } });
      const byId = runStateful(dir, ["layout", "export", "--workspace", "ws_api"]);
      expect(JSON.parse(byId.stdout).name).toBe("api");
      const dup = runStateful(dir, ["layout", "export", "--workspace", "dup"]);
      expect(dup.status).toBe(2);
      expect(dup.stderr).toContain("ws_dup1 ws_dup2");
      const missing = runStateful(dir, ["layout", "export", "--workspace", "nope"]);
      expect(missing.status).toBe(2);
      expect(missing.stderr).toContain("no workspace 'nope'");
      const empty = runStateful(dir, ["layout", "export", "--workspace", "ws_empty"]);
      expect(empty.status).toBe(1);
      expect(empty.stderr).toContain("no layout yet");
      const raw = runStateful(dir, ["layout", "export", "--raw"]);
      expect(JSON.parse(raw.stdout).root.kind).toBe("split");
      expect(JSON.parse(raw.stdout).screen_id).toBe("screen_1");
    });
  });

  describe("layout apply", () => {
    test("builds a 3-pane document with the exact op sequence and reports every surface", () => {
      const dir = makeStatefulDir();
      writeFileSync(join(dir, "dev.json"), JSON.stringify(LAYOUT_DOC));
      const run = runStateful(dir, ["layout", "apply", "--json", join(dir, "dev.json")]);
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      const base = `${dir}/work/app`;
      expect(run.calls.map(stripRoute)).toEqual([
        ["--json", "workspace", "create", "--empty", "--name", "dev"],
        // slot 0: the root pane is the first leaf's first terminal itself (exact argv, no placeholder).
        ["--json", "workspace", "ws_new1", "run", "--on-exit", "keep", "--cwd", base, "--name", "agent", "--", "env", "NODE_ENV=development", "bash", "-l"],
        // split before either half is filled; the new pane starts in the second child's first cwd.
        ["--json", "pane", "pane_2", "split", "--right", "--ratio", "0.4", "--cwd", base],
        ["--json", "terminal", "term_2", ...PROMPT_WAIT],
        ["--json", "terminal", "term_2", "write", "--text", "claude"],
        ["--json", "terminal", "term_2", "keys", "enter"],
        ["--json", "pane", "pane_2", "tab", "create", "browser", "--url", "http://localhost:3000", "--name", "app"],
        ["--json", "pane", "pane_3", "split", "--down", "--ratio", "0.7", "--cwd", "/var/log"],
        // a split-created pane: real terminal first (workspace env + surface env), then its placeholder dies.
        ["--json", "pane", "pane_3", "run", "--on-exit", "keep", "--cwd", base, "--name", "tests", "--", "env", "NODE_ENV=development", "CI=1", "bash", "-l"],
        ["--json", "terminal", "term_3", "close"],
        ["--json", "terminal", "term_9", ...PROMPT_WAIT],
        ["--json", "terminal", "term_9", "write", "--text", "bun test --watch"],
        ["--json", "terminal", "term_9", "keys", "enter"],
        ["--json", "pane", "pane_8", "run", "--on-exit", "keep", "--cwd", "/var/log", "--", "env", "NODE_ENV=development", "bash", "-l"],
        ["--json", "terminal", "term_8", "close"],
        ["--json", "pane", "pane_8", "focus"],
      ]);
      expect(JSON.parse(run.stdout)).toEqual({
        workspace_id: "ws_new1",
        workspace_name: "dev",
        panes: [
          {
            pane_id: "pane_2",
            surfaces: [
              { type: "terminal", name: "agent", terminal_id: "term_2", tab_id: "tab_2" },
              { type: "browser", name: "app", browser_id: "browser_7", tab_id: "tab_7" },
            ],
          },
          { pane_id: "pane_3", surfaces: [{ type: "terminal", name: "tests", terminal_id: "term_9", tab_id: "tab_9" }] },
          { pane_id: "pane_8", surfaces: [{ type: "terminal", terminal_id: "term_14", tab_id: "tab_14" }] },
        ],
        warnings: [],
      });
      const human = runStateful(dir, ["layout", "apply", join(dir, "dev.json")]);
      expect(human.stdout.trim()).toBe("OK workspace=ws_new1 name=dev panes=3 surfaces=4");
    });

    test("--workspace builds inside an EMPTY existing workspace and refuses one that already has panes", () => {
      const dir = makeStatefulDir();
      writeFileSync(join(dir, "dev.json"), JSON.stringify(LAYOUT_DOC));
      const busy = runStateful(dir, ["layout", "apply", "--workspace", "ws_main", join(dir, "dev.json")]);
      expect(busy.status).toBe(1);
      expect(busy.stderr).toContain("ws_main already has a layout (4 panes)");
      expect(busy.calls.map(stripRoute)).toEqual([["--json", "session", "current", "snapshot"]]);
      const empty = runStateful(dir, ["layout", "apply", "--workspace", "empty", join(dir, "dev.json")]);
      expect(empty.status).toBe(0);
      expect(empty.stdout.trim()).toBe("OK workspace=ws_empty name=empty panes=3 surfaces=4");
      expect(empty.calls.map(stripRoute)[1].slice(0, 4)).toEqual(["--json", "workspace", "ws_empty", "run"]);
      expect(empty.calls.some((call) => stripRoute(call).slice(0, 3).join(" ") === "--json workspace create")).toBe(false);
      const both = runStateful(dir, ["layout", "apply", "--workspace", "x", "--name", "y", join(dir, "dev.json")]);
      expect(both.status).toBe(2);
      expect(both.calls).toEqual([]);
    });

    test("an older daemon without --empty: the starter terminal is the root placeholder and is replaced", () => {
      const dir = makeStatefulDir();
      const doc = { pane: { surfaces: [{ type: "terminal", name: "shell" }] } };
      const run = runStateful(dir, ["layout", "apply", "--json", "-"], { FAKE_NO_EMPTY: "1" }, JSON.stringify(doc));
      expect(run.status).toBe(0);
      expect(run.calls.map(stripRoute)).toEqual([
        ["--json", "workspace", "create", "--empty", "--name", "layout"],
        ["--json", "workspace", "create", "--name", "layout"],
        ["--json", "pane", "pane_2", "run", "--on-exit", "keep", "--cwd", dir, "--name", "shell", "--", "bash", "-l"],
        ["--json", "terminal", "term_2", "close"],
        ["--json", "pane", "pane_2", "focus"],
      ]);
      expect(JSON.parse(run.stdout).panes).toEqual([{ pane_id: "pane_2", surfaces: [{ type: "terminal", name: "shell", terminal_id: "term_3", tab_id: "tab_3" }] }]);
    });

    test("a browser surface the daemon cannot open becomes a warning and the pane keeps its shell", () => {
      const dir = makeStatefulDir();
      const doc = {
        direction: "vertical",
        children: [{ pane: { surfaces: [{ type: "terminal" }] } }, { pane: { surfaces: [{ type: "browser", url: "http://localhost:8080" }, { type: "project", cwd: "x" }] } }],
      };
      const run = runStateful(dir, ["layout", "apply", "--json", "--name", "web", "-"], { FAKE_NO_BROWSER: "1" }, JSON.stringify(doc));
      expect(run.status).toBe(0);
      const ops = run.calls.map(stripRoute);
      expect(ops).toContainEqual(["--json", "pane", "pane_3", "tab", "create", "browser", "--url", "http://localhost:8080"]);
      // The placeholder shell (term_3) stays: nothing closes it.
      expect(ops.some((call) => call[1] === "terminal" && call[3] === "close")).toBe(false);
      const summary = JSON.parse(run.stdout);
      expect(summary.workspace_name).toBe("web");
      expect(summary.panes).toEqual([{ pane_id: "pane_2", surfaces: [{ type: "terminal", terminal_id: "term_2", tab_id: "tab_2" }] }]);
      expect(summary.warnings.length).toBe(2);
      expect(summary.warnings[0]).toContain("http://localhost:8080");
      expect(summary.warnings[1]).toContain("Mac-only");
      expect(run.stderr).toContain("warning");
    });

    test.each([false, true])("uses the saved layout name without workspace metadata (explicit override: %s)", (override) => {
      const dir = makeStatefulDir();
      const saved = { name: "saved-dev", workspace: { layout: { pane: { surfaces: [{ type: "terminal" }] } } } };
      const args = ["layout", "apply", "--json", ...(override ? ["--name", "explicit"] : []), "-"];
      const run = runStateful(dir, args, {}, JSON.stringify(saved));
      expect(run.status).toBe(0);
      const expectedName = override ? "explicit" : "saved-dev";
      expect(run.calls.map(stripRoute)[0]).toEqual(["--json", "workspace", "create", "--empty", "--name", expectedName]);
      expect(JSON.parse(run.stdout).workspace_name).toBe(expectedName);
    });

    test("accepts a saved layout wrapper and a bare node; rejects malformed documents with the JSON path", () => {
      const dir = makeStatefulDir();
      const saved = { name: "dev", description: "x", workspace: { name: "from-saved", cwd: "~/src", layout: { pane: { surfaces: [{ type: "terminal", cwd: "app" }] } } } };
      const savedRun = runStateful(dir, ["layout", "apply", "-"], {}, JSON.stringify(saved));
      expect(savedRun.status).toBe(0);
      expect(savedRun.calls.map(stripRoute)[0]).toEqual(["--json", "workspace", "create", "--empty", "--name", "dev"]);
      expect(savedRun.calls.map(stripRoute)[1]).toEqual(["--json", "workspace", "ws_new1", "run", "--on-exit", "keep", "--cwd", `${dir}/src/app`, "--", "bash", "-l"]);

      const bare = runStateful(dir, ["layout", "apply", "-"], {}, JSON.stringify({ pane: { surfaces: [{ type: "terminal" }] } }));
      expect(bare.status).toBe(0);
      expect(bare.stdout).toContain("name=layout");

      const cases: Array<[unknown, string]> = [
        [{ direction: "horizontal", children: [{ pane: { surfaces: [] } }] }, "$.children: split needs exactly 2 children"],
        [{ pane: { surfaces: [{ type: "widget" }] } }, "$.pane.surfaces[0].type: must be terminal, browser, or project"],
        [{ layout: { direction: "diagonal", children: [{ pane: { surfaces: [{ type: "terminal" }] } }, { pane: { surfaces: [{ type: "terminal" }] } }] } }, "$.layout.direction: must be horizontal or vertical"],
        [{ direction: "vertical", children: [{ pane: { surfaces: [{ type: "terminal" }] } }, { pane: { surfaces: [{ type: "browser" }] } }] }, "$.children[1].pane.surfaces[0].url: browser surface needs url"],
        [{ workspace: { layout: { pane: { surfaces: [] } } } }, "$.workspace.layout.pane.surfaces: needs at least one surface"],
        [{ name: "nothing here" }, "$: no layout found"],
      ];
      for (const [doc, message] of cases) {
        const run = runStateful(dir, ["layout", "apply", "-"], {}, JSON.stringify(doc));
        expect(run.status).toBe(2);
        expect(run.stderr).toContain(message);
        expect(run.calls).toEqual([]);
      }
      const notJson = runStateful(dir, ["layout", "apply", "-"], {}, "not json");
      expect(notJson.status).toBe(2);
      expect(notJson.stderr).toContain("not valid JSON");
    });
  });

  describe("env", () => {
    test("set writes sorted, quoted exports with mode 0600 and installs the shell hook exactly once", () => {
      const dir = makeStatefulDir();
      const run = runStateful(dir, ["env", "set", "FOO=bar", "BAZ=it's here", "ZED=1"]);
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      expect(run.stdout).toContain("OK set 3 variables");
      const file = join(dir, ".config", "cmux", "env");
      expect(readFileSync(file, "utf8")).toBe(
        "# managed by cmux env; KEY='value' lines; edit with cmux env set/rm\nexport BAZ='it'\\''s here'\nexport FOO='bar'\nexport ZED='1'\n",
      );
      expect(statSync(file).mode & 0o777).toBe(0o600);
      const hook = '[ -f "$HOME/.config/cmux/env" ] && . "$HOME/.config/cmux/env" # cmux-env-hook';
      runStateful(dir, ["env", "set", "FOO=again"]);
      for (const rc of [".profile", ".bashrc"]) {
        const text = readFileSync(join(dir, rc), "utf8");
        expect(text.split(hook).length - 1).toBe(1);
      }
      expect(existsSync(join(dir, ".bash_profile"))).toBe(false);
      // The file is real shell: sourcing it yields the values, quotes and all.
      const sourced = spawnSync("sh", ["-c", `. "${file}"; printf '%s|%s|%s' "$FOO" "$BAZ" "$ZED"`], { encoding: "utf8" });
      expect(sourced.stdout).toBe("again|it's here|1");
    });

    test("--from-file and stdin understand dotenv comments, export prefixes, and quotes; later keys win", () => {
      const dir = makeStatefulDir();
      writeFileSync(join(dir, "dot.env"), "# comment\nexport API_KEY=\"abc def\" # a quote: \"\nDB_URL='postgres://x' # comment\n\nPLAIN=1\r\nPLAIN=2\n");
      const fromFile = runStateful(dir, ["env", "set", "--from-file", join(dir, "dot.env")]);
      expect(fromFile.status).toBe(0);
      const fromStdin = runStateful(dir, ["env", "set", "-"], {}, "X=1\nexport  Y = spaced\n");
      expect(fromStdin.status).toBe(0);
      const shown = runStateful(dir, ["env", "ls", "--show"]);
      expect(shown.stdout).toBe("API_KEY=abc def\nDB_URL=postgres://x\nPLAIN=2\nX=1\nY=spaced\n");
      const names = runStateful(dir, ["env", "ls"]);
      expect(names.stdout).toBe("API_KEY\nDB_URL\nPLAIN\nX\nY\n");
      const json = runStateful(dir, ["env", "ls", "--json", "--show"]);
      expect(JSON.parse(json.stdout)).toEqual({
        path: join(dir, ".config", "cmux", "env"),
        keys: ["API_KEY", "DB_URL", "PLAIN", "X", "Y"],
        values: { API_KEY: "abc def", DB_URL: "postgres://x", PLAIN: "2", X: "1", Y: "spaced" },
      });
      expect(JSON.parse(runStateful(dir, ["env", "ls", "--json"]).stdout)).toEqual({ path: join(dir, ".config", "cmux", "env"), keys: ["API_KEY", "DB_URL", "PLAIN", "X", "Y"] });
    });

    test("dotenv quote handling preserves literal hashes and backslashes", () => {
      const dir = makeStatefulDir();
      const input = 'HASH="a # b" # comment\nESCAPED="a\\" # b" # comment\nPLAIN=raw # comment\n';
      expect(runStateful(dir, ["env", "set", "-"], {}, input).status).toBe(0);
      const values = JSON.parse(runStateful(dir, ["env", "ls", "--json", "--show"]).stdout).values;
      expect(values).toEqual({ HASH: "a # b", ESCAPED: 'a\\" # b', PLAIN: "raw" });
    });

    test("dotenv sources and explicit assignments are applied in argument order", () => {
      const dir = makeStatefulDir();
      const file = join(dir, "ordered.env");
      writeFileSync(file, "KEY=file\n");
      // The stdin marker is in the middle. A parser that defers stdin until after
      // argv would incorrectly make it win over the later explicit assignment.
      expect(runStateful(dir, ["env", "set", "KEY=first", "--from-file", file, "-", "KEY=after-stdin"], {}, "KEY=stdin\n").status).toBe(0);
      expect(JSON.parse(runStateful(dir, ["env", "ls", "--json", "--show"]).stdout).values.KEY).toBe("after-stdin");
    });

    test("explicit assignments preserve literal quotes, hashes, and surrounding whitespace", () => {
      const dir = makeStatefulDir();
      expect(runStateful(dir, ["env", "set", 'VALUE= "quoted" # literal ']).status).toBe(0);
      expect(JSON.parse(runStateful(dir, ["env", "ls", "--json", "--show"]).stdout).values.VALUE).toBe(' "quoted" # literal ');
      expect(runStateful(dir, ["env", "set", "VALUE=line\nINJECTED=yes"]).status).toBe(2);
      expect(JSON.parse(runStateful(dir, ["env", "ls", "--json", "--show"]).stdout).values).toEqual({ VALUE: ' "quoted" # literal ' });
    });

    test("rm removes only the named keys; invalid keys and empty sets are usage errors; path prints the file", () => {
      const dir = makeStatefulDir();
      runStateful(dir, ["env", "set", "A=1", "B=2", "C=3"]);
      const rm = runStateful(dir, ["env", "rm", "A", "C"]);
      expect(rm.status).toBe(0);
      expect(runStateful(dir, ["env", "ls"]).stdout).toBe("B\n");
      expect(runStateful(dir, ["env", "set", "1BAD=x"]).status).toBe(2);
      expect(runStateful(dir, ["env", "set", "BAD-KEY=x"]).status).toBe(2);
      expect(runStateful(dir, ["env", "set", "novalue"]).status).toBe(2);
      expect(runStateful(dir, ["env", "set"]).status).toBe(2);
      expect(runStateful(dir, ["env", "rm"]).status).toBe(2);
      expect(runStateful(dir, ["env", "path"]).stdout.trim()).toBe(join(dir, ".config", "cmux", "env"));
      const fresh = makeStatefulDir();
      expect(runStateful(fresh, ["env", "ls"]).stdout).toContain("no machine env yet");
      expect(JSON.parse(runStateful(fresh, ["env", "ls", "--json"]).stdout)).toEqual({ path: join(fresh, ".config", "cmux", "env"), keys: [] });
    });

    test("env receive --stdin: READY first, then OK with the key count; values are byte-literal", () => {
      const dir = makeStatefulDir();
      const payload = "FOO=bar\nBAZ=it's  here \nURL=postgres://u:p%40ss@h/db?x=1\n";
      const b64 = Buffer.from(payload, "utf8").toString("base64").replace(/(.{20})/g, "$1\n");
      const run = runStateful(dir, ["env", "receive", "--stdin"], {}, `${b64}\n\nCMUX-ENV-END\n`);
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      const file = join(dir, ".config", "cmux", "env");
      expect(run.stdout).toBe(`CMUX-ENV-READY\nCMUX-ENV-OK keys=3 path=${file}\n`);
      expect(readFileSync(file, "utf8")).toBe(
        "# managed by cmux env; KEY='value' lines; edit with cmux env set/rm\nexport BAZ='it'\\''s  here '\nexport FOO='bar'\nexport URL='postgres://u:p%40ss@h/db?x=1'\n",
      );
      expect(statSync(file).mode & 0o777).toBe(0o600);
      expect(readFileSync(join(dir, ".profile"), "utf8")).toContain("cmux-env-hook");
      expect(run.calls).toEqual([]);
    });

    test("env receive refuses bad keys, truncated streams, and garbage without writing anything", () => {
      const dir = makeStatefulDir();
      const badKey = runStateful(dir, ["env", "receive", "--stdin"], {}, `${Buffer.from("OK=1\n1BAD=x\n").toString("base64")}\nCMUX-ENV-END\n`);
      expect(badKey.status).toBe(1);
      expect(badKey.stdout).toBe("CMUX-ENV-READY\nCMUX-ENV-ERR invalid-key 1BAD\n");
      expect(existsSync(join(dir, ".config", "cmux", "env"))).toBe(false);
      const noEnd = runStateful(dir, ["env", "receive", "--stdin"], {}, `${Buffer.from("A=1\n").toString("base64")}\n`);
      expect(noEnd.status).toBe(1);
      expect(noEnd.stdout).toBe("CMUX-ENV-READY\nCMUX-ENV-ERR eof\n");
      const garbage = runStateful(dir, ["env", "receive", "--stdin"], {}, "!!!not base64!!!\nCMUX-ENV-END\n");
      expect(garbage.status).toBe(1);
      expect(garbage.stdout).toContain("CMUX-ENV-ERR bad-base64");
      const empty = runStateful(dir, ["env", "receive", "--stdin"], {}, "CMUX-ENV-END\n");
      expect(empty.status).toBe(1);
      expect(empty.stdout).toContain("CMUX-ENV-ERR empty");
      expect(existsSync(join(dir, ".config", "cmux", "env"))).toBe(false);
    });

    test("agents started through the shim see the machine env", () => {
      const dir = makeStatefulDir();
      runStateful(dir, ["env", "set", "CMUX_TEST_TOKEN=from-env"]);
      const claude = join(dir, "claude");
      writeFileSync(claude, "#!/bin/sh\nprintf '%s\\n' \"$CMUX_TEST_TOKEN\"\n");
      chmodSync(claude, 0o755);
      const run = runStateful(dir, ["agent", "claude", "say hi"]);
      expect(run.status).toBe(0);
      expect(run.stdout.trim()).toBe("from-env");
    });

    test("agent --wait/--output are already how this form runs; --timeout caps it with timeout(1)", () => {
      const dir = makeStatefulDir();
      const claude = join(dir, "claude");
      writeFileSync(claude, "#!/bin/sh\nprintf '%s\\n' \"$*\"\nif [ \"${SLOW:-0}\" = 1 ]; then sleep 5; fi\n");
      chmodSync(claude, 0o755);
      // The flags are stripped only when they lead; the agent sees the prompt form it always saw.
      const plain = runStateful(dir, ["agent", "claude", "--wait", "--output", "--", "say", "hi"]);
      expect(plain.stderr).toBe("");
      expect(plain.status).toBe(0);
      expect(plain.stdout).toBe("-p say hi\n");
      expect(plain.calls).toEqual([]);
      const capped = runStateful(dir, ["agent", "claude", "--timeout=30", "say hi"]);
      expect(capped.status).toBe(0);
      expect(capped.stdout).toBe("-p say hi\n");
      // Anything after the agent's own first token is the agent's, untouched.
      expect(runStateful(dir, ["agent", "claude", "--resume", "--wait"]).stdout).toBe("--resume --wait\n");
      expect(runStateful(dir, ["agent", "claude", "--timeout", "nope", "x"]).status).toBe(2);
      const hasTimeout = spawnSync("sh", ["-c", "command -v timeout || command -v gtimeout"], { encoding: "utf8" }).status === 0;
      if (hasTimeout) {
        const slow = runStateful(dir, ["agent", "claude", "--timeout", "0.5", "--", "x"], { SLOW: "1" });
        expect(slow.status).toBe(1);
        expect(slow.stderr).toContain("agent claude timed out after 0.5s");
      }
    });
  });

  describe("peer forms", () => {
    // A live link: the shim reuses ~/.cmux/peer-links/<peer>.{pid,sock-path}
    // when the pid is alive and the socket exists, so the peer verbs can be
    // exercised without a cmux-remote daemon.
    let server: ReturnType<typeof createServer> | undefined;
    let sockPath = "";
    const peer = "brave-otter";

    function peerDir(): string {
      const dir = makeStatefulDir();
      mkdirSync(join(dir, ".cmux", "peers"), { recursive: true });
      mkdirSync(join(dir, ".cmux", "peer-links"), { recursive: true });
      writeFileSync(join(dir, ".cmux", "peers", `${peer}.json`), JSON.stringify({ route: "cmux-remote://example" }));
      writeFileSync(join(dir, ".cmux", "peer-links", `${peer}.pid`), String(process.pid));
      writeFileSync(join(dir, ".cmux", "peer-links", `${peer}.sock-path`), sockPath);
      return dir;
    }

    beforeAll(async () => {
      sockPath = `/tmp/cmux-gs-${process.pid}-${Math.random().toString(36).slice(2, 8)}.sock`;
      server = createServer();
      await new Promise<void>((resolve, reject) => {
        server!.once("error", reject);
        server!.listen(sockPath, resolve);
      });
    });
    afterAll(async () => {
      if (server) await new Promise<void>((resolve) => server!.close(() => resolve()));
      try {
        unlinkSync(sockPath);
      } catch {
        // already gone
      }
    });

    test("terminal verbs ride the peer's link socket with the same flags as locally", () => {
      const dir = peerDir();
      const send = runStateful(dir, ["vm", "terminal", "send", peer, "term_x", "bun test", "--keys", "enter"]);
      expect(send.stderr).toBe("");
      expect(send.status).toBe(0);
      expect(send.calls).toEqual([
        ["--socket", sockPath, "terminal", "term_x", "write", "--text", "bun test"],
        ["--socket", sockPath, "terminal", "term_x", "keys", "enter"],
      ]);
      expect(runStateful(dir, ["vm", "terminal", "read", peer, "term_x"]).calls).toEqual([["--socket", sockPath, "terminal", "term_x", "screen", "read"]]);
      expect(runStateful(dir, ["vm", "terminal", "wait", peer, "term_x", "--pattern", "ok", "--timeout", "1"]).calls).toEqual([
        ["--socket", sockPath, "--json", "terminal", "term_x", "screen", "wait", "--pattern", "ok", "--timeout-ms", "1000"],
      ]);
      expect(runStateful(dir, ["vm", "terminal", "close", peer, "term_x"]).calls).toEqual([["--socket", sockPath, "terminal", "term_x", "close"]]);
      expect(runStateful(dir, ["vm", "send", peer, "term_x", "hello", "world"]).calls).toEqual([["--socket", sockPath, "terminal", "term_x", "write", "--text", "hello world"]]);
      expect(runStateful(dir, ["vm", "send-key", peer, "term_x", "ctrl+c"]).calls).toEqual([["--socket", sockPath, "terminal", "term_x", "keys", "ctrl+c"]]);
      expect(runStateful(dir, ["vm", "read-screen", peer, "term_x", "--json"]).calls).toEqual([["--socket", sockPath, "--json", "terminal", "term_x", "screen", "read"]]);
      // cmux-tui's own grammar on the peer is untouched.
      expect(runStateful(dir, ["vm", "terminal", peer, "list"]).calls).toEqual([["--socket", sockPath, "terminal", "list"]]);
    });

    test("workspace new/rename/close/rm; rm kills every terminal viewed in the workspace first", () => {
      const dir = peerDir();
      expect(runStateful(dir, ["vm", "workspace", "new", peer, "--name", "tests"]).calls).toEqual([["--socket", sockPath, "workspace", "create", "--name", "tests"]]);
      expect(runStateful(dir, ["vm", "workspace", "rename", peer, "ws_a", "renamed"]).calls).toEqual([["--socket", sockPath, "workspace", "ws_a", "rename", "--name", "renamed"]]);
      expect(runStateful(dir, ["vm", "workspace", "close", peer, "ws_a"]).calls).toEqual([["--socket", sockPath, "workspace", "ws_a", "close"]]);
      const rm = runStateful(dir, ["vm", "workspace", "rm", peer, "ws_main"]);
      expect(rm.status).toBe(0);
      expect(rm.calls).toEqual([
        ["--socket", sockPath, "--json", "session", "current", "snapshot"],
        ["--socket", sockPath, "terminal", "term_agent", "close"],
        ["--socket", sockPath, "terminal", "term_logs", "close"],
        ["--socket", sockPath, "terminal", "term_shell", "close"],
        ["--socket", sockPath, "terminal", "term_tests", "close"],
        ["--socket", sockPath, "workspace", "ws_main", "close"],
      ]);
      expect(rm.stdout).toContain("4 terminals closed");
      // Passthrough for cmux-tui's own workspace grammar.
      expect(runStateful(dir, ["vm", "workspace", peer, "list"]).calls).toEqual([["--socket", sockPath, "workspace", "list"]]);
    });

    test("agent starts a durable terminal on the peer running the peer's own `cmux agent`", () => {
      const dir = peerDir();
      const run = runStateful(dir, ["vm", "agent", peer, "--agent", "claude", "--cwd", "/root/work/app", "--", "fix", "the tests"]);
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      expect(run.calls).toEqual([
        ["--socket", sockPath, "workspace", "current", "show"],
        ["--socket", sockPath, "--json", "workspace", "current", "run", "--on-exit", "keep", "--name", "claude", "--cwd", "/root/work/app", "--", "cmux", "agent", "claude", "fix", "the tests"],
      ]);
      expect(run.stdout).toContain(`OK terminal=term_2 workspace=current machine=${peer} agent=claude`);
      // No current workspace on the peer yet → `main` is created and used.
      const fresh = runStateful(dir, ["vm", "agent", peer, "codex", "--name", "docs", "--", "write docs"], { FAKE_NO_CURRENT: "1" });
      expect(fresh.status).toBe(0);
      expect(fresh.calls.map((call) => call.slice(2))).toEqual([
        ["workspace", "current", "show"],
        ["--json", "workspace", "create", "--name", "main"],
        ["--json", "workspace", "ws_new2", "run", "--on-exit", "keep", "--name", "docs", "--", "cmux", "agent", "codex", "write docs"],
      ]);
      expect(runStateful(dir, ["vm", "agent", peer, "--agent", "emacs", "--", "x"]).status).toBe(2);
      // `vm agent <peer> list` is still cmux-tui's agent scope on the peer.
      expect(runStateful(dir, ["vm", "agent", peer, "list"]).calls).toEqual([["--socket", sockPath, "agent", "list"]]);
    });

    test("vm env set delivers values only inside the typed base64 payload of the receive handshake", () => {
      const dir = peerDir();
      const secret = "s3cr3t value with spaces";
      const run = runStateful(dir, ["vm", "env", "set", peer, `TOKEN=${secret}`, "-"], {}, "OTHER=two\n");
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      const ops = run.calls.map((call) => call.slice(2));
      expect(ops[0]).toEqual(["workspace", "current", "show"]);
      expect(ops[1]).toEqual(["--json", "workspace", "current", "run", "--on-exit", "keep", "--name", "cmux env", "--", "cmux", "env", "receive"]);
      expect(ops[2]).toEqual(["--json", "terminal", "term_2", "screen", "wait", "--pattern", "CMUX-ENV-READY", "--timeout-ms", "15000"]);
      const writes = ops.filter((call) => call[1] === "terminal" && call[3] === "write");
      expect(writes.length).toBeGreaterThan(0);
      for (const write of writes) expect(write.slice(0, 5)).toEqual(["--json", "terminal", "term_2", "write", "--bytes-base64"]);
      const stream = Buffer.concat(writes.map((write) => Buffer.from(write[5], "base64"))).toString("utf8");
      const lines = stream.split("\n");
      expect(lines.at(-1)).toBe("");
      expect(lines.at(-2)).toBe("CMUX-ENV-END");
      const inner = lines.slice(0, -2).join("");
      expect(Buffer.from(inner, "base64").toString("utf8")).toBe(`TOKEN=${secret}\nOTHER=two\n`);
      expect(ops.at(-2)).toEqual(["--json", "terminal", "term_2", "screen", "wait", "--pattern", "CMUX-ENV-(OK|ERR)", "--timeout-ms", "30000"]);
      expect(ops.at(-1)).toEqual(["--json", "terminal", "term_2", "close"]);
      // The secret is nowhere in argv except inside the base64 payload.
      for (const call of run.calls) {
        for (const word of call) {
          if (call[3] === "write") continue;
          expect(word).not.toContain("s3cr3t");
        }
      }
      expect(run.stdout).toContain(`OK set 2 variables on ${peer}: TOKEN OTHER`);
      // A receiver that never says READY: the terminal is closed and the command fails.
      const notReady = runStateful(dir, ["vm", "env", "set", peer, "A=1"], { FAKE_MATCHED: "false" });
      expect(notReady.status).toBe(1);
      expect(notReady.stderr).toContain("never became ready");
      expect(notReady.calls.at(-1)?.slice(2)).toEqual(["--json", "terminal", "term_2", "close"]);
    });

    test("vm push types one file into the peer's cmux file receive over the link; only the payload carries the bytes", () => {
      const dir = peerDir();
      const secret = Buffer.concat([Buffer.from("API_KEY=s3cr3t-value\n", "utf8"), Buffer.from([0, 1, 2, 255, 10])]);
      writeFileSync(join(dir, "local.env"), secret);
      const run = runStateful(dir, ["vm", "push", peer, join(dir, "local.env"), "/root/app/.env", "--mode", "640"], { FAKE_FILE_BYTES: String(secret.length) });
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      const ops = run.calls.map(stripRoute);
      expect(ops[0]).toEqual(["workspace", "current", "show"]);
      expect(ops[1]).toEqual(["--json", "workspace", "current", "run", "--on-exit", "keep", "--name", "cmux file", "--", "cmux", "file", "receive", "/root/app/.env", "--mode", "640"]);
      expect(ops[2]).toEqual(["--json", "terminal", "term_2", "screen", "wait", "--pattern", "CMUX-FILE-READY", "--timeout-ms", "15000"]);
      const writes = ops.filter((call) => call[1] === "terminal" && call[3] === "write");
      expect(writes.length).toBeGreaterThan(0);
      for (const write of writes) expect(write.slice(0, 5)).toEqual(["--json", "terminal", "term_2", "write", "--bytes-base64"]);
      const stream = Buffer.concat(writes.map((write) => Buffer.from(write[5], "base64"))).toString("utf8");
      const lines = stream.split("\n");
      expect(lines.at(-1)).toBe("");
      expect(lines.at(-2)).toBe("CMUX-FILE-END");
      expect(lines.slice(0, -2).every((line) => line.length <= 76)).toBe(true);
      expect(Buffer.from(lines.slice(0, -2).join(""), "base64").equals(secret)).toBe(true);
      expect(ops.at(-2)).toEqual(["--json", "terminal", "term_2", "screen", "wait", "--pattern", "CMUX-FILE-(OK|ERR)", "--timeout-ms", "30000"]);
      expect(ops.at(-1)).toEqual(["--json", "terminal", "term_2", "close"]);
      for (const call of run.calls) {
        if (call[3] === "write") continue;
        for (const word of call) expect(word).not.toContain("s3cr3t");
      }
      expect(run.stdout).toBe(`OK /root/app/.env on ${peer} (${secret.length} bytes, mode 640) delivered over the link\n`);
      // --json, the Mac's --secret spelling, and a relative remote path (resolved under the peer's $HOME by the receiver).
      const json = runStateful(dir, ["vm", "push", "--secret", peer, join(dir, "local.env"), "app/.env", "--json"], { FAKE_FILE_PATH: "/root/app/.env", FAKE_FILE_MODE: "600" });
      expect(json.status).toBe(0);
      expect(JSON.parse(json.stdout)).toEqual({ machine: peer, path: "/root/app/.env", bytes: secret.length, mode: "600", transport: "link" });
      expect(json.calls.map(stripRoute)[1]?.slice(-5)).toEqual(["file", "receive", "app/.env", "--mode", "600"]);
      // Refusals happen before anything touches the link.
      mkdirSync(join(dir, "tree"));
      const directory = runStateful(dir, ["vm", "push", peer, join(dir, "tree"), "/root/tree"]);
      expect(directory.status).toBe(2);
      expect(directory.stderr).toContain("is a directory");
      expect(directory.calls).toEqual([]);
      expect(runStateful(dir, ["vm", "push", peer, join(dir, "missing.env"), "/root/x"]).status).toBe(2);
      expect(runStateful(dir, ["vm", "push", peer, join(dir, "local.env"), "/root/x", "--mode", "999"]).status).toBe(2);
      expect(runStateful(dir, ["vm", "push", peer, join(dir, "local.env")]).status).toBe(2);
      writeFileSync(join(dir, "big.bin"), Buffer.alloc(262145, 7));
      const big = runStateful(dir, ["vm", "push", peer, join(dir, "big.bin"), "/root/big.bin"]);
      expect(big.status).toBe(2);
      expect(big.stderr).toContain("256 KiB");
      expect(big.calls).toEqual([]);
      // A receiver that never says READY: the terminal is closed and the command fails.
      const notReady = runStateful(dir, ["vm", "push", peer, join(dir, "local.env"), "/root/x"], { FAKE_MATCHED: "false" });
      expect(notReady.status).toBe(1);
      expect(notReady.stderr).toContain("never became ready");
      expect(notReady.calls.at(-1)?.slice(2)).toEqual(["--json", "terminal", "term_2", "close"]);
      // A receiver that refuses before READY (its reason is on the screen) is relayed verbatim.
      const refused = runStateful(dir, ["vm", "push", peer, join(dir, "local.env"), "/root/app"], { FAKE_FILE_REFUSE: "1" });
      expect(refused.status).toBe(1);
      expect(refused.stderr).toContain(`vm push on ${peer} failed: is-directory /root/app`);
      expect(refused.calls.at(-1)?.slice(2)).toEqual(["--json", "terminal", "term_2", "close"]);
    });

    test("agent --wait blocks on the peer terminal's exit, --output pages its stream, and the exit code is the agent's", () => {
      const dir = peerDir();
      const waited = runStateful(dir, ["vm", "agent", peer, "--agent", "claude", "--wait", "--", "fix", "the tests"]);
      expect(waited.status).toBe(3);
      expect(waited.stdout).toBe("exited code=3\n");
      expect(waited.stderr).toBe(`started terminal=term_2 workspace=current machine=${peer} agent=claude; waiting\n`);
      expect(waited.calls.map(stripRoute)).toEqual([
        ["workspace", "current", "show"],
        ["--json", "workspace", "current", "run", "--on-exit", "keep", "--name", "claude", "--", "cmux", "agent", "claude", "fix", "the tests"],
        ["--json", "terminal", "term_2", "process", "wait", "--timeout-ms", "30000"],
      ]);
      // --output implies --wait and pages the stream by next_offset until complete.
      const output = runStateful(dir, ["vm", "agent", peer, "claude", "--output", "--", "fix"], { FAKE_OUTPUT_PAGED: "1" });
      expect(output.status).toBe(3);
      expect(output.stdout).toBe("line one\nline two\n");
      expect(output.calls.map(stripRoute).slice(2)).toEqual([
        ["--json", "terminal", "term_2", "process", "wait", "--timeout-ms", "30000"],
        ["--json", "terminal", "term_2", "output", "read", "--after", "0"],
        ["--json", "terminal", "term_2", "output", "read", "--after", "9"],
      ]);
      // Still running after two slices: the daemon is asked again until it exits.
      const eventually = runStateful(dir, ["vm", "agent", peer, "claude", "--wait", "--", "x"], { FAKE_EXIT_PENDING_UNTIL: "5" });
      expect(eventually.status).toBe(3);
      expect(eventually.stdout).toBe("exited code=3\n");
      expect(eventually.calls.filter((call) => call[5] === "process").length).toBe(3);
      // --timeout is sliced into daemon waits of at most 30 s; when it runs out the agent keeps running there.
      const slow = runStateful(dir, ["vm", "agent", peer, "--agent", "codex", "--wait", "--timeout", "45", "--", "x"], { FAKE_EXIT_PENDING: "1" });
      expect(slow.status).toBe(1);
      expect(slow.stdout).toBe("pending\n");
      expect(slow.calls.map(stripRoute).filter((call) => call[3] === "process")).toEqual([
        ["--json", "terminal", "term_2", "process", "wait", "--timeout-ms", "30000"],
        ["--json", "terminal", "term_2", "process", "wait", "--timeout-ms", "15000"],
      ]);
      expect(slow.stderr).toContain(`agent codex on ${peer} is still running after 45s (terminal term_2`);
      expect(slow.stderr).toContain(`cmux vm terminal wait-exit ${peer} term_2`);
      // With --output the partial stream is still printed before the timeout verdict.
      const slowOutput = runStateful(dir, ["vm", "agent", peer, "claude", "--output", "--timeout", "0.5", "--", "x"], { FAKE_EXIT_PENDING: "1" });
      expect(slowOutput.status).toBe(1);
      expect(slowOutput.stdout).toBe("line one\nline two\n");
      expect(slowOutput.stderr).toContain("--after 18");
      const killed = runStateful(dir, ["vm", "agent", peer, "claude", "--wait", "--", "x"], { FAKE_EXIT_KIND: "signal" });
      expect(killed.status).toBe(1);
      expect(killed.stdout).toBe("exited signal=9\n");
      expect(killed.stderr).toContain("ended by a signal");
      // JSON: one object with the outcome and, with --output, the stream; nothing on stderr.
      const json = runStateful(dir, ["vm", "agent", peer, "--agent", "claude", "--wait", "--output", "--json", "--", "x"]);
      expect(json.status).toBe(3);
      expect(json.stderr).toBe("");
      expect(JSON.parse(json.stdout)).toEqual({ terminal_id: "term_2", workspace_id: "current", machine: peer, agent: "claude", state: "exited", exit_code: 3, signal: null, output: "line one\nline two\n", next_offset: 18 });
      const jsonSignal = runStateful(dir, ["vm", "agent", peer, "claude", "--wait", "--json", "--", "x"], { FAKE_EXIT_KIND: "signal" });
      expect(JSON.parse(jsonSignal.stdout)).toMatchObject({ state: "exited", exit_code: null, signal: 9 });
      const jsonPending = runStateful(dir, ["vm", "agent", peer, "claude", "--wait", "--json", "--timeout", "1", "--", "x"], { FAKE_EXIT_PENDING: "1" });
      expect(jsonPending.status).toBe(1);
      expect(JSON.parse(jsonPending.stdout)).toMatchObject({ state: "pending", exit_code: null, signal: null });
      // Detached --json names the terminal so a later wait-exit/output can find it.
      const detached = runStateful(dir, ["vm", "agent", peer, "--agent", "claude", "--json", "--", "x"]);
      expect(detached.status).toBe(0);
      expect(JSON.parse(detached.stdout)).toEqual({ terminal_id: "term_2", workspace_id: "current", machine: peer, agent: "claude", state: "running" });
      expect(detached.calls.filter((call) => call[5] === "process")).toEqual([]);
      expect(runStateful(dir, ["vm", "agent", peer, "claude", "--wait", "--timeout", "nope", "--", "x"]).status).toBe(2);
    });

    test("layout, env, exec, and tree on a peer use the same functions over the link socket", () => {
      const dir = peerDir();
      const exported = runStateful(dir, ["vm", "layout", "export", peer, "--workspace", "api"]);
      expect(exported.status).toBe(0);
      expect(exported.calls).toEqual([["--socket", sockPath, "--json", "session", "current", "snapshot"]]);
      expect(JSON.parse(exported.stdout).layout).toEqual({ pane: { surfaces: [{ type: "terminal", cwd: "/root/work/api" }] } });
      const applied = runStateful(dir, ["vm", "layout", "apply", peer, "--name", "remote", "-"], {}, JSON.stringify({ pane: { surfaces: [{ type: "terminal" }] } }));
      expect(applied.status).toBe(0);
      expect(applied.calls[0]).toEqual(["--socket", sockPath, "--json", "workspace", "create", "--empty", "--name", "remote"]);
      expect(runStateful(dir, ["vm", "env", "ls", peer, "--json"]).calls).toEqual([
        ["--socket", sockPath, "workspace", "current", "show"],
        ["--socket", sockPath, "workspace", "current", "run", "--on-exit", "close", "--", "cmux", "env", "ls", "--json"],
      ]);
      expect(runStateful(dir, ["vm", "env", "rm", peer, "K"]).calls.at(-1)).toEqual(["--socket", sockPath, "workspace", "current", "run", "--on-exit", "close", "--", "cmux", "env", "rm", "K"]);
      expect(runStateful(dir, ["vm", "exec", peer, "--", "echo", "hi there"]).calls.at(-1)).toEqual(["--socket", sockPath, "workspace", "current", "run", "--on-exit", "close", "--", "echo", "hi there"]);
      expect(runStateful(dir, ["vm", "tree", peer]).calls).toEqual([["--socket", sockPath, "--json", "session", "current", "snapshot"]]);
      const unlinked = runStateful(dir, ["vm", "terminal", "read", "unknown-peer", "term_x"]);
      expect(unlinked.status).toBe(2);
      expect(unlinked.stderr).toContain("no link for machine 'unknown-peer'");
      expect(unlinked.calls).toEqual([]);
    });
  });

  test("the whole apply flow also runs under dash (the image's sh)", () => {
    if (!existsSync("/bin/dash")) return;
    const dir = makeStatefulDir();
    const run = runStateful(dir, ["layout", "apply", "--json", "-"], {}, JSON.stringify(LAYOUT_DOC), "/bin/dash");
    expect(run.stderr).toBe("");
    expect(run.status).toBe(0);
    expect(JSON.parse(run.stdout).panes.map((pane: { pane_id: string }) => pane.pane_id)).toEqual(["pane_2", "pane_3", "pane_8"]);
    const env = runStateful(dir, ["env", "set", "A=x y"], {}, undefined, "/bin/dash");
    expect(env.status).toBe(0);
    expect(runStateful(dir, ["env", "ls", "--show"], {}, undefined, "/bin/dash").stdout).toBe("A=x y\n");
  });
});

// ---------------------------------------------------------------------------
// Reflection: the machine asking the control plane who it is and what it can
// reach, through the model-plane alias (the edge injects the VM-bound route
// token). The server side is /api/vm/reflection/* (superset of /api/vm/self);
// here a fake curl plays it.
// ---------------------------------------------------------------------------
/** The owner's machines as the control plane lists them (VmSelfMachine + route/reachable/network), newest first, the caller included. */
const REFLECTION_MACHINES = [
  { id: "fs-build", vmId: "11111111-2222-4333-8444-555555555555", name: "Build box", displayName: "Build box", slug: "build-box", status: "running", createdAt: "2026-09-06T00:00:00.000Z", self: true, route: null, reachable: false, network: { ipv4: "10.0.0.2", ipv6: "fd00::2" } },
  { id: "fs-a", vmId: "aaaa", name: "Reviewer", displayName: "Reviewer", slug: "brave-otter", status: "running", createdAt: "2026-09-05T00:00:00.000Z", self: false, route: "ws://[fd00::4]:1337/v1/link", reachable: true, network: { ipv4: "10.0.0.4", ipv6: "fd00::4" } },
  { id: "fs-b", vmId: "bbbb", name: "Sleepy", displayName: "Sleepy", slug: "sleepy-otter", status: "running", createdAt: "2026-09-04T00:00:00.000Z", self: false, route: "ws://[fd00::5]:1337/v1/link", reachable: true, network: { ipv4: "10.0.0.5", ipv6: "fd00::5" } },
  { id: "fs-c", vmId: "cccc", name: "asleep-mole", displayName: null, slug: "asleep-mole", status: "paused", createdAt: "2026-09-03T00:00:00.000Z", self: false, route: null, reachable: false, network: { ipv4: null, ipv6: null } },
];
/** A reflection index from before the superset: identity only, no machine/machines. */
const REFLECTION_INDEX_PLAIN = {
  name: "build-box",
  display_name: "Build box",
  emoji: null,
  vm_id: "11111111-2222-4333-8444-555555555555",
  provider_vm_id: "fs-build",
  status: "running",
  created_at: "2026-09-06T00:00:00.000Z",
  owner: { user_id: "user_1", email: "owner@example.com", display_name: "Owner" },
  team_id: "team_1",
  plan_id: "pro",
  urls: { reflection: ["https://coderouter.cmux.internal/api/vm/reflection", "https://reflection.cmux.internal/"] },
  paths: [{ path: "/owner", description: "owner of this machine" }, { path: "/peers", description: "other machines" }],
};
const REFLECTION_INDEX = { schema: 1, ...REFLECTION_INDEX_PLAIN, machine: REFLECTION_MACHINES[0], team: { id: "team_1" }, machines: REFLECTION_MACHINES };
/** GET /api/vm/self, the bootstrap shim's endpoint: no owner/plan, no routes. */
const withoutRoute = ({ id, vmId, name, displayName, slug, status, createdAt, self }: (typeof REFLECTION_MACHINES)[number]) => ({ id, vmId, name, displayName, slug, status, createdAt, self });
const SELF_LEGACY = { schema: 1, machine: withoutRoute(REFLECTION_MACHINES[0]), team: { id: "team_1" }, machines: REFLECTION_MACHINES.map(withoutRoute) };
const REFLECTION_PEERS = {
  peers: [
    { name: "brave-otter", display_name: "Reviewer", vm_id: "aaaa", provider_vm_id: "fs-a", status: "running", network: { ipv4: "10.0.0.4", ipv6: "fd00::4" }, route: "ws://[fd00::4]:1337/v1/link", reachable: true, help: "cmux vm exec brave-otter -- <command>" },
    { name: "sleepy-otter", display_name: "Sleepy", vm_id: "bbbb", provider_vm_id: "fs-b", status: "running", network: { ipv4: "10.0.0.5", ipv6: "fd00::5" }, route: "ws://[fd00::5]:1337/v1/link", reachable: true, help: "cmux vm exec sleepy-otter -- <command>" },
    { name: "asleep-mole", display_name: null, vm_id: "cccc", provider_vm_id: "fs-c", status: "paused", network: { ipv4: null, ipv6: null }, route: null, reachable: false, help: "cmux vm exec asleep-mole -- <command>" },
  ],
};
const REFLECTION_INTEGRATIONS = { integrations: [{ type: "llm", name: "coderouter", help: "cmux coderouter models" }] };

/**
 * A curl that answers the reflection paths, /api/vm/self, and the CodeRouter usage probe by URL
 * suffix. It speaks both capture styles: `-o <file>` + `-w '%{http_code}'` (the auth probes) and
 * the bootstrap shim's body-then-status on stdout (`--write-out '\n%{http_code}'`).
 * CMUX_TEST_REFLECTION=deny|down simulates no identity / no edge; plain = a reflection server
 * before the superset; legacy = no reflection at all (index 404), only /api/vm/self.
 */
function fakeReflectionCurl(directory: string): void {
  const body = (value: unknown) => JSON.stringify(value).replace(/'/g, "'\\''");
  writeFileSync(
    join(directory, "curl"),
    `#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --cacert|-w|--write-out|-H|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\\n' "$url" >> "$HOME/curl.log"
answer() {
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; printf '%s' "$1"; else printf '%s\\n%s' "$2" "$1"; fi
}
mode="\${CMUX_TEST_REFLECTION:-ok}"
case "$mode" in
  down) exit 7 ;;
  deny) answer 401 '{"error":"vm_principal_required","message":"only a cmux Cloud machine can call reflection"}'; exit 0 ;;
esac
case "$url" in
  */api/vm/reflection)
    case "$mode" in
      legacy) answer 404 '{"error":"not_found","message":"no such route"}' ;;
      plain) answer 200 '${body(REFLECTION_INDEX_PLAIN)}' ;;
      *) answer 200 '${body(REFLECTION_INDEX)}' ;;
    esac ;;
  */api/vm/self) answer 200 '${body(SELF_LEGACY)}' ;;
  */api/vm/reflection/peers) answer 200 '${body(REFLECTION_PEERS)}' ;;
  */api/vm/reflection/integrations) answer 200 '${body(REFLECTION_INTEGRATIONS)}' ;;
  */api/coderouter/vm-usage/self) answer 200 '{}' ;;
  *) answer 404 '{"error":"not_found","message":"no such path"}' ;;
esac
`,
  );
  chmodSync(join(directory, "curl"), 0o755);
}

const REFLECTION_ENV = { CMUX_CODEROUTER_URL: "https://coderouter.cmux.internal", OPENAI_API_KEY: "cmux-vm-edge-placeholder" };
const SELF_HUMAN = "Build box\tfs-build\trunning\t(this machine)\nteam\tteam_1\t4 machines\nowner\towner@example.com\nplan\tpro\n";
const VM_LS_HUMAN = "* Build box\tfs-build\trunning\t(this machine)\n  Reviewer\tfs-a\trunning\treachable\tlinked\n  Sleepy\tfs-b\trunning\treachable\tconnected\n  asleep-mole\tfs-c\tpaused\tunreachable\n";

/** Peer files as the Mac or a first `cmux vm exec` leaves them: brave-otter linked, Sleepy linked with a live link process. */
function linkTwoPeers(directory: string): void {
  mkdirSync(join(directory, ".cmux", "peers"), { recursive: true });
  mkdirSync(join(directory, ".cmux", "peer-links"), { recursive: true });
  writeFileSync(join(directory, ".cmux", "peers", "brave-otter.json"), JSON.stringify({ route: "ws://[fd00::4]:1337/v1/link" }));
  writeFileSync(join(directory, ".cmux", "peers", "Sleepy.json"), JSON.stringify({ route: "ws://[fd00::5]:1337/v1/link" }));
  writeFileSync(join(directory, ".cmux", "peer-links", "Sleepy.pid"), String(process.pid));
}

describe("in-VM cmux shim: reflection", () => {
  test("self prints who this machine is, human and JSON; whoami and reflect are aliases", () => {
    const run = runShim(["self"], REFLECTION_ENV, fakeReflectionCurl);
    expect(run.stderr).toBe("");
    expect(run.status).toBe(0);
    expect(run.stdout).toBe(SELF_HUMAN);
    const json = runShim(["self", "--json"], REFLECTION_ENV, fakeReflectionCurl);
    expect(json.status).toBe(0);
    expect(JSON.parse(json.stdout)).toEqual(REFLECTION_INDEX);
    // The probe carries only the public placeholder bearer: the edge adds the real token.
    expect(json.stdout).not.toContain("crt_");
    expect(runShim(["whoami"], REFLECTION_ENV, fakeReflectionCurl).stdout).toBe(SELF_HUMAN);
    expect(runShim(["reflect"], REFLECTION_ENV, fakeReflectionCurl).stdout).toBe(SELF_HUMAN);
    expect(JSON.parse(runShim(["whoami", "--json"], REFLECTION_ENV, fakeReflectionCurl).stdout)).toEqual(REFLECTION_INDEX);
  });

  test("self answers without the daemon binary: identity precedes cmux-tui on a fresh machine", () => {
    const run = runShim(["self"], { ...REFLECTION_ENV, CMUX_TUI_BIN: "/nonexistent/cmux-tui" }, fakeReflectionCurl);
    expect(run.stderr).toBe("");
    expect(run.status).toBe(0);
    expect(run.stdout).toBe(SELF_HUMAN);
    expect(runShim(["vm", "ls", "--json"], { ...REFLECTION_ENV, CMUX_TUI_BIN: "/nonexistent/cmux-tui" }, fakeReflectionCurl).status).toBe(0);
    // Everything else still needs the daemon.
    const tree = runShim(["tree"], { ...REFLECTION_ENV, CMUX_TUI_BIN: "/nonexistent/cmux-tui" }, fakeReflectionCurl);
    expect(tree.status).toBe(1);
    expect(tree.stderr).toContain("/nonexistent/cmux-tui");
  });

  test("self explains a missing alias, a machine without identity, and an unreachable edge", () => {
    const unconfigured = runShim(["self"]);
    expect(unconfigured.status).toBe(2);
    expect(unconfigured.stdout).toBe("");
    const denied = runShim(["self"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "deny" }, fakeReflectionCurl);
    expect(denied.status).toBe(1);
    expect(denied.stderr).toContain("this machine has no VM identity");
    expect(denied.stderr).toContain("HTTP 401");
    const down = runShim(["self"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "down" }, fakeReflectionCurl);
    expect(down.status).toBe(1);
    expect(down.stderr).toContain("reflection unreachable at https://coderouter.cmux.internal/api/vm/reflection");
  });

  test("self <path> passes any reflection path through and surfaces server errors", () => {
    const peers = runShim(["self", "peers"], REFLECTION_ENV, fakeReflectionCurl);
    expect(peers.status).toBe(0);
    expect(JSON.parse(peers.stdout)).toEqual(REFLECTION_PEERS);
    expect(JSON.parse(runShim(["self", "/integrations", "--json"], REFLECTION_ENV, fakeReflectionCurl).stdout)).toEqual(REFLECTION_INTEGRATIONS);
    expect(JSON.parse(runShim(["reflect", "peers/"], REFLECTION_ENV, fakeReflectionCurl).stdout)).toEqual(REFLECTION_PEERS);
    const missing = runShim(["self", "nope"], REFLECTION_ENV, fakeReflectionCurl);
    expect(missing.status).toBe(1);
    expect(missing.stderr).toContain("HTTP 404");
    expect(missing.stderr).toContain("no such path");
    expect(runShim(["self", "peers?x=1"], REFLECTION_ENV, fakeReflectionCurl).status).toBe(2);
    expect(runShim(["self", "--bogus"], REFLECTION_ENV, fakeReflectionCurl).status).toBe(2);
    expect(runShim(["self", "peers", "owner"], REFLECTION_ENV, fakeReflectionCurl).status).toBe(2);
  });

  test("self falls back to GET /api/vm/self when the control plane has no reflection index", () => {
    const dir = mkdtempSync(join(tmpdir(), "cmux-guest-legacy-"));
    const run = runShim(["self"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "legacy", HOME: dir }, (directory) => {
      fakeReflectionCurl(directory);
      fakeReflectionCurl(dir);
    });
    expect(run.stderr).toBe("");
    expect(run.status).toBe(0);
    // No owner or plan there; the same first lines as main's bootstrap `cmux self`.
    expect(run.stdout).toBe("Build box\tfs-build\trunning\t(this machine)\nteam\tteam_1\t4 machines\n");
    expect(readFileSync(join(dir, "curl.log"), "utf8").trim().split("\n")).toEqual([
      "https://coderouter.cmux.internal/api/vm/reflection",
      "https://coderouter.cmux.internal/api/vm/self",
    ]);
    expect(JSON.parse(runShim(["self", "--json"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "legacy" }, fakeReflectionCurl).stdout)).toEqual(SELF_LEGACY);
    // A pre-superset reflection index still identifies the machine; it just cannot count the fleet.
    const plain = runShim(["self"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "plain" }, fakeReflectionCurl);
    expect(plain.status).toBe(0);
    expect(plain.stdout).toBe("Build box\tfs-build\trunning\t(this machine)\nteam\tteam_1\nowner\towner@example.com\nplan\tpro\n");
  });

  test("auth status reports the identity next to the daemon and CodeRouter checks", () => {
    const run = runShim(["auth", "status", "--json"], REFLECTION_ENV, fakeReflectionCurl);
    expect(run.status).toBe(0);
    const payload = JSON.parse(run.stdout) as Record<string, any>;
    expect(payload.authenticated).toBe(true);
    expect(payload.identity).toEqual({ vm_id: "11111111-2222-4333-8444-555555555555", name: "build-box" });
    const human = runShim(["auth", "status"], REFLECTION_ENV, fakeReflectionCurl);
    expect(human.stdout).toContain("Identity: build-box (11111111-2222-4333-8444-555555555555)");
    const denied = runShim(["auth", "status", "--json"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "deny" }, fakeReflectionCurl);
    expect((JSON.parse(denied.stdout) as Record<string, any>).identity).toBeNull();
    expect(runShim(["auth", "status"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "deny" }, fakeReflectionCurl).stdout).toContain("Identity: unavailable (reflection: this machine has no VM identity");
    // Without an alias the field is still present, so JSON readers never see a missing key.
    expect((JSON.parse(runShim(["auth", "status", "--json"]).stdout) as Record<string, any>).identity).toBeNull();
  });

  test("vm ls lists the owner's machines: this one marked, reachability, and this machine's link state", () => {
    const dir = makeStatefulDir();
    fakeReflectionCurl(dir);
    linkTwoPeers(dir);
    const run = runStateful(dir, ["vm", "ls"], REFLECTION_ENV);
    expect(run.stderr).toBe("");
    expect(run.status).toBe(0);
    expect(run.stdout).toBe(VM_LS_HUMAN);
    expect(run.calls).toEqual([]);
    // list, peers, and links are silent aliases of the one listing.
    for (const alias of ["list", "peers", "links"]) {
      expect(runStateful(dir, ["vm", alias], REFLECTION_ENV).stdout).toBe(VM_LS_HUMAN);
    }
    const json = runStateful(dir, ["vm", "ls", "--json"], REFLECTION_ENV);
    expect(json.status).toBe(0);
    expect(JSON.parse(json.stdout)).toEqual({ machines: REFLECTION_MACHINES });
    expect(runStateful(dir, ["vm", "ls", "--bogus"], REFLECTION_ENV).status).toBe(2);
  });

  test("vm ls reads the same list from /peers or /api/vm/self when the index predates machines[]", () => {
    const dir = makeStatefulDir();
    fakeReflectionCurl(dir);
    linkTwoPeers(dir);
    // A reflection server before the superset: the index plus /peers give the same lines.
    const plain = runStateful(dir, ["vm", "ls"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "plain" });
    expect(plain.stderr).toBe("");
    expect(plain.stdout).toBe(VM_LS_HUMAN);
    const plainJson = JSON.parse(runStateful(dir, ["vm", "ls", "--json"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "plain" }).stdout) as { machines: Array<Record<string, unknown>> };
    expect(plainJson.machines.map((machine) => [machine.name, machine.id, machine.self, machine.reachable, machine.route])).toEqual([
      ["Build box", "fs-build", true, false, null],
      ["Reviewer", "fs-a", false, true, "ws://[fd00::4]:1337/v1/link"],
      ["Sleepy", "fs-b", false, true, "ws://[fd00::5]:1337/v1/link"],
      ["asleep-mole", "fs-c", false, false, null],
    ]);
    // No reflection at all: /api/vm/self knows the machines but not their routes.
    const legacy = runStateful(dir, ["vm", "ls"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "legacy" });
    expect(legacy.stderr).toBe("");
    expect(legacy.stdout).toBe("* Build box\tfs-build\trunning\t(this machine)\n  Reviewer\tfs-a\trunning\tlinked\n  Sleepy\tfs-b\trunning\tconnected\n  asleep-mole\tfs-c\tpaused\n");
    expect(JSON.parse(runStateful(dir, ["vm", "ls", "--json"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "legacy" }).stdout)).toEqual({ machines: SELF_LEGACY.machines });
    // Nothing is invented when the control plane cannot answer.
    const down = runStateful(dir, ["vm", "ls"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "down" });
    expect(down.status).toBe(1);
    expect(down.stdout).toBe("");
    expect(down.stderr).toContain("reflection unreachable");
    expect(runStateful(dir, ["vm", "ls"]).status).toBe(2);
  });

  describe("peer discovery through reflection", () => {
    let server: ReturnType<typeof createServer> | undefined;
    let sockPath = "";
    beforeAll(async () => {
      sockPath = `/tmp/cmux-gr-${process.pid}-${Math.random().toString(36).slice(2, 8)}.sock`;
      server = createServer();
      await new Promise<void>((resolve, reject) => {
        server!.once("error", reject);
        server!.listen(sockPath, resolve);
      });
    });
    afterAll(async () => {
      if (server) await new Promise<void>((resolve) => server!.close(() => resolve()));
      try {
        unlinkSync(sockPath);
      } catch {
        // already gone
      }
    });

    test("a peer with no link file is looked up in /peers, its route is written, and the link dials it", () => {
      const dir = makeStatefulDir();
      fakeReflectionCurl(dir);
      const run = runStateful(dir, ["vm", "terminal", "read", "sleepy-otter", "term_x"], { ...REFLECTION_ENV, FAKE_LINK_SOCKET: sockPath });
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      const peerFile = JSON.parse(readFileSync(join(dir, ".cmux", "peers", "sleepy-otter.json"), "utf8"));
      expect(peerFile).toEqual({ route: "ws://[fd00::5]:1337/v1/link", name: "sleepy-otter", vm_id: "bbbb", provider_vm_id: "fs-b", source: "reflection" });
      expect(statSync(join(dir, ".cmux", "peers", "sleepy-otter.json")).mode & 0o777).toBe(0o600);
      const connect = run.calls.find((call) => call[0] === "remote" && call[1] === "connect");
      expect(connect?.slice(0, 5)).toEqual(["remote", "connect", "ws://[fd00::5]:1337/v1/link", "--headless", "--json"]);
      expect(connect).not.toContain("--invite-file");
      expect(run.calls.at(-1)).toEqual(["--socket", sockPath, "terminal", "term_x", "screen", "read"]);
      // Display name and ids resolve to the same machine; the file is reused on the next call.
      const byDisplay = runStateful(dir, ["vm", "terminal", "read", "Sleepy", "term_y"], { ...REFLECTION_ENV, FAKE_LINK_SOCKET: sockPath });
      expect(byDisplay.status).toBe(0);
      expect(JSON.parse(readFileSync(join(dir, ".cmux", "peers", "Sleepy.json"), "utf8")).route).toBe("ws://[fd00::5]:1337/v1/link");
    });

    test("wait-exit and output take the same road to a peer terminal", () => {
      const dir = makeStatefulDir();
      fakeReflectionCurl(dir);
      const exit = runStateful(dir, ["vm", "terminal", "wait-exit", "sleepy-otter", "term_x", "--timeout", "2"], { ...REFLECTION_ENV, FAKE_LINK_SOCKET: sockPath });
      expect(exit.stderr).toBe("");
      expect(exit.status).toBe(0);
      expect(exit.stdout).toBe("exited code=3\n");
      expect(exit.calls.at(-1)).toEqual(["--socket", sockPath, "--json", "terminal", "term_x", "process", "wait", "--timeout-ms", "2000"]);
      const output = runStateful(dir, ["vm", "terminal", "output", "sleepy-otter", "term_x", "--after", "18"], { ...REFLECTION_ENV, FAKE_LINK_SOCKET: sockPath });
      expect(output.status).toBe(0);
      expect(output.stdout).toBe("line one\nline two\n");
      expect(output.calls.at(-1)).toEqual(["--socket", sockPath, "--json", "terminal", "term_x", "output", "read", "--after", "18"]);
    });

    test("unknown, route-less, and reflection-less peers fail closed with the reason", () => {
      const dir = makeStatefulDir();
      fakeReflectionCurl(dir);
      const unknown = runStateful(dir, ["vm", "terminal", "read", "no-such", "term_x"], REFLECTION_ENV);
      expect(unknown.status).toBe(2);
      expect(unknown.stderr).toContain("no link for machine 'no-such'");
      expect(unknown.stderr).toContain("reachable machines: brave-otter, sleepy-otter, asleep-mole");
      expect(unknown.calls).toEqual([]);
      const routeless = runStateful(dir, ["vm", "terminal", "read", "asleep-mole", "term_x"], REFLECTION_ENV);
      expect(routeless.status).toBe(2);
      expect(routeless.stderr).toContain("no private-network route");
      expect(existsSync(join(dir, ".cmux", "peers", "asleep-mole.json"))).toBe(false);
      const down = runStateful(dir, ["vm", "terminal", "read", "sleepy-otter", "term_x"], { ...REFLECTION_ENV, CMUX_TEST_REFLECTION: "down" });
      expect(down.status).toBe(2);
      expect(down.stderr).toContain("no link for machine 'sleepy-otter': reflection unreachable");
      const unconfigured = runStateful(dir, ["vm", "terminal", "read", "sleepy-otter", "term_x"]);
      expect(unconfigured.status).toBe(2);
      expect(unconfigured.stderr).toContain("no model-plane alias is configured");
    });
  });

  test("help is one page in the Mac's grammar: this machine, who am I, other machines, the human, models, auth", () => {
    const run = runShim(["--help"]);
    expect(run.status).toBe(0);
    const sections = ["THIS MACHINE", "WHO AM I", "OTHER MACHINES", "REACH THE HUMAN", "MODELS AND AGENTS", "AUTH"];
    const positions = sections.map((section) => run.stdout.indexOf(section));
    expect(positions.every((position) => position >= 0)).toBe(true);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);
    expect(run.stdout).toContain("cmux self [--json]");
    expect(run.stdout).toContain("cmux vm ls [--json]");
    expect(run.stdout).toContain("cmux vm exec <machine> -- <cmd...>");
    expect(run.stdout).toContain("cmux notify --title <text>");
    // One spelling per concept: whoami/reflect appear only as aliases, and no verb is listed twice.
    expect(run.stdout).not.toContain("cmux whoami [--json]");
    expect(run.stdout).not.toContain("cmux vm peers");
    expect(runShim(["vm", "help"]).stdout).toContain("cmux vm ls [--json]");
    for (const alias of [["self", "--help"], ["whoami", "--help"], ["reflect", "-h"]]) {
      const help = runShim(alias);
      expect(help.status).toBe(0);
      expect(help.stdout).toContain("cmux self peers [--json]");
      expect(help.stdout).toContain("cmux whoami = cmux self");
    }
    const terminalHelp = runShim(["terminal", "help"]);
    expect(terminalHelp.stdout).toContain("cmux terminal wait-exit <id> [--timeout <seconds>] [--json]");
    expect(terminalHelp.stdout).toContain("cmux terminal output <id> [--after <offset>] [--max-bytes <n>] [--json]");
  });
});

describe("in-VM cmux shim: file drop", () => {
  const stream = (bytes: Buffer) => `${bytes.toString("base64").replace(/(.{76})/g, "$1\n")}\nCMUX-FILE-END\n`;

  test("file receive: READY, base64 lines, END; the bytes land by rename with the mode and parents asked for", () => {
    const dir = makeStatefulDir();
    const payload = Buffer.concat([Buffer.from(Array.from({ length: 256 }, (_, i) => i)), Buffer.from(Array.from({ length: 256 }, (_, i) => i))]);
    const run = runStateful(dir, ["file", "receive", "secrets/deep/key.bin", "--mode", "640", "--stdin"], {}, stream(payload));
    expect(run.stderr).toBe("");
    expect(run.status).toBe(0);
    const file = join(dir, "secrets", "deep", "key.bin");
    expect(run.stdout).toBe(`CMUX-FILE-READY\nCMUX-FILE-OK bytes=${payload.length} path=${file} mode=640\n`);
    expect(readFileSync(file).equals(payload)).toBe(true);
    expect(statSync(file).mode & 0o777).toBe(0o640);
    expect(statSync(join(dir, "secrets")).mode & 0o777).toBe(0o700);
    expect(statSync(join(dir, "secrets", "deep")).mode & 0o777).toBe(0o700);
    expect(readdirSync(join(dir, "secrets", "deep"))).toEqual(["key.bin"]);
    expect(run.calls).toEqual([]);
    // Default mode 600, absolute path, and an existing file is replaced atomically (no temp file survives).
    const target = join(dir, "app.env");
    writeFileSync(target, "old\n");
    const replaced = runStateful(dir, ["file", "receive", target, "--stdin"], {}, stream(Buffer.from("NEW=1\n")));
    expect(replaced.status).toBe(0);
    expect(replaced.stdout).toBe(`CMUX-FILE-READY\nCMUX-FILE-OK bytes=6 path=${target} mode=600\n`);
    expect(readFileSync(target, "utf8")).toBe("NEW=1\n");
    expect(statSync(target).mode & 0o777).toBe(0o600);
    expect(readdirSync(dir).filter((name) => name.startsWith(".cmux-file."))).toEqual([]);
    // CRLF line ends and blank lines from a PTY are tolerated; --mode=0755 is the four-digit form.
    const crlf = runStateful(dir, ["file", "receive", "bin/run.sh", "--mode=0755", "--stdin"], {}, stream(Buffer.from("#!/bin/sh\necho hi\n")).replace(/\n/g, "\r\n\r\n"));
    expect(crlf.status).toBe(0);
    expect(statSync(join(dir, "bin", "run.sh")).mode & 0o777).toBe(0o755);
    expect(readFileSync(join(dir, "bin", "run.sh"), "utf8")).toBe("#!/bin/sh\necho hi\n");
  });

  test("file receive refuses garbage, truncation, empty and oversize payloads, directories and bad modes without leaving anything behind", () => {
    const dir = makeStatefulDir();
    mkdirSync(join(dir, "dest"));
    const garbage = runStateful(dir, ["file", "receive", "dest/x", "--stdin"], {}, "!!!not base64!!!\nCMUX-FILE-END\n");
    expect(garbage.status).toBe(1);
    expect(garbage.stdout).toBe("CMUX-FILE-READY\nCMUX-FILE-ERR bad-base64\n");
    const truncated = runStateful(dir, ["file", "receive", "dest/x", "--stdin"], {}, `${Buffer.from("abc").toString("base64")}\n`);
    expect(truncated.status).toBe(1);
    expect(truncated.stdout).toBe("CMUX-FILE-READY\nCMUX-FILE-ERR eof\n");
    const empty = runStateful(dir, ["file", "receive", "dest/x", "--stdin"], {}, "CMUX-FILE-END\n");
    expect(empty.status).toBe(1);
    expect(empty.stdout).toBe("CMUX-FILE-READY\nCMUX-FILE-ERR empty\n");
    const big = runStateful(dir, ["file", "receive", "dest/x", "--stdin"], {}, stream(Buffer.alloc(262145, 1)));
    expect(big.status).toBe(1);
    expect(big.stdout).toBe("CMUX-FILE-READY\nCMUX-FILE-ERR too-large\n");
    const exact = runStateful(dir, ["file", "receive", "dest/max", "--stdin"], {}, stream(Buffer.alloc(262144, 1)));
    expect(exact.status).toBe(0);
    expect(statSync(join(dir, "dest", "max")).size).toBe(262144);
    expect(readdirSync(join(dir, "dest"))).toEqual(["max"]);
    const directory = runStateful(dir, ["file", "receive", "dest", "--stdin"], {}, stream(Buffer.from("x")));
    expect(directory.status).toBe(1);
    expect(directory.stdout).toBe(`CMUX-FILE-ERR is-directory ${join(dir, "dest")}\n`);
    // Usage errors answer before READY, so a sender sees the reason on the screen instead of a silent timeout.
    const badMode = runStateful(dir, ["file", "receive", "dest/x", "--mode", "9", "--stdin"], {}, stream(Buffer.from("x")));
    expect(badMode.status).toBe(2);
    expect(badMode.stdout).toBe("CMUX-FILE-ERR bad-mode 9\n");
    const noPath = runStateful(dir, ["file", "receive", "--stdin"], {}, stream(Buffer.from("x")));
    expect(noPath.status).toBe(2);
    expect(noPath.stdout).toBe("CMUX-FILE-ERR usage cmux file receive <path> [--mode <octal>]\n");
    expect(runStateful(dir, ["file", "bogus"]).status).toBe(2);
    expect(runStateful(dir, ["file", "bogus"]).stderr).toContain("unknown file command");
  });

  test("the receiver also runs under dash (the image's sh)", () => {
    if (!existsSync("/bin/dash")) return;
    const dir = makeStatefulDir();
    const payload = Buffer.from("hello from dash\n");
    const run = runStateful(dir, ["file", "receive", "d/out.txt", "--stdin"], {}, stream(payload), "/bin/dash");
    expect(run.stderr).toBe("");
    expect(run.status).toBe(0);
    expect(readFileSync(join(dir, "d", "out.txt"), "utf8")).toBe("hello from dash\n");
  });
});

describe("in-VM cmux shim: terminal exit and output", () => {
  test("wait-exit blocks on process wait and reports the exit the way the Mac CLI does", () => {
    const dir = makeStatefulDir();
    const run = runStateful(dir, ["terminal", "wait-exit", "term_x", "--timeout", "5"]);
    expect(run.stderr).toBe("");
    expect(run.status).toBe(0);
    expect(run.stdout).toBe("exited code=3\n");
    expect(run.calls).toEqual([["--session", "cloud", "--json", "terminal", "term_x", "process", "wait", "--timeout-ms", "5000"]]);
    // No timeout: the daemon waits as long as it takes.
    expect(runStateful(dir, ["terminal", "wait-exit", "term_x"]).calls).toEqual([["--session", "cloud", "--json", "terminal", "term_x", "process", "wait"]]);
    expect(runStateful(dir, ["terminal", "wait-exit", "term_x"], { FAKE_EXIT_KIND: "signal" }).stdout).toBe("exited signal=9\n");
    const json = runStateful(dir, ["terminal", "wait-exit", "term_x", "--json"]);
    expect(json.status).toBe(0);
    expect(JSON.parse(json.stdout).value).toMatchObject({ state: "exited", outcome: { kind: "exit", code: 3 } });
    // Still running: say so on stdout and exit 1, so scripts can loop on it.
    const pending = runStateful(dir, ["terminal", "wait-exit", "term_x", "--timeout", "0.5"], { FAKE_EXIT_PENDING: "1" });
    expect(pending.status).toBe(1);
    expect(pending.stdout).toBe("pending\n");
    expect(pending.calls.at(-1)?.slice(-2)).toEqual(["--timeout-ms", "500"]);
    const pendingJson = runStateful(dir, ["terminal", "wait-exit", "term_x", "--json"], { FAKE_EXIT_PENDING: "1" });
    expect(pendingJson.status).toBe(1);
    expect(JSON.parse(pendingJson.stdout).value.state).toBe("pending");
    expect(runStateful(dir, ["terminal", "wait-exit", "term_x", "--timeout", "nope"]).status).toBe(2);
    expect(runStateful(dir, ["terminal", "wait-exit"]).status).toBe(2);
  });

  test("output reads the terminal's stream by offset and prints only the text unless --json", () => {
    const dir = makeStatefulDir();
    const run = runStateful(dir, ["terminal", "output", "term_x", "--after", "5", "--max-bytes", "100"]);
    expect(run.stderr).toBe("");
    expect(run.status).toBe(0);
    expect(run.stdout).toBe("line one\nline two\n");
    expect(run.calls).toEqual([["--session", "cloud", "--json", "terminal", "term_x", "output", "read", "--after", "5", "--max-bytes", "100"]]);
    expect(runStateful(dir, ["terminal", "output", "term_x"]).calls).toEqual([["--session", "cloud", "--json", "terminal", "term_x", "output", "read"]]);
    const json = runStateful(dir, ["terminal", "output", "term_x", "--json"]);
    expect(json.status).toBe(0);
    expect(JSON.parse(json.stdout).value).toEqual({ terminal_id: "term_x", text: "line one\nline two\n", start_offset: 0, next_offset: 18, complete: true });
    for (const bad of [["--max-bytes", "0"], ["--max-bytes", "4194305"], ["--after", "x"], ["--bogus"]]) {
      expect(runStateful(dir, ["terminal", "output", "term_x", ...bad]).status).toBe(2);
    }
  });
});

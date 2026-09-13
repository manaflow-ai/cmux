import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { createServer } from "node:net";
import path from "node:path";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";
import {
  GUEST_CMUX_SELF_SHIM,
  GUEST_CMUX_SELF_SHIM_PATH,
  guestSelfCliInstallCommand,
} from "../services/vms/guestSelfCli";

// The guest `cmux` shim, run for real under /bin/sh against a fake `curl` on
// PATH that records the request and replays a canned /api/vm/self body. jq
// must be present, as it is in the devbox image.

const SELF_BODY = {
  schema: 1,
  machine: { id: "fs-self", vmId: "v-self", name: "builder", displayName: "builder", slug: "sleepy-red-fox", status: "running", createdAt: "2026-09-01T00:00:00.000Z", self: true },
  team: { id: "team-1" },
  machines: [
    { id: "fs-sibling", vmId: "v-sib", name: "quiet-teal-otter", displayName: null, slug: "quiet-teal-otter", status: "paused", createdAt: "2026-09-02T00:00:00.000Z", self: false },
    { id: "fs-self", vmId: "v-self", name: "builder", displayName: "builder", slug: "sleepy-red-fox", status: "running", createdAt: "2026-09-01T00:00:00.000Z", self: true },
  ],
};

let root = "";
let bin = "";
let home = "";
let requestLog = "";

const fakeCurl = (body: string, status: string, fail = false) => `#!/bin/sh
printf '%s\\n' "$*" >> "${requestLog}"
${fail ? `echo "curl: (6) Could not resolve host: coderouter.cmux.internal" >&2; printf '\\n000'; exit 6` : `printf '%s\\n%s' '${body.replace(/'/g, `'\\''`)}' '${status}'`}
`;

const run = (args: string[], env: Record<string, string> = {}) =>
  spawnSync("/bin/sh", [path.join(bin, "cmux"), ...args], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}`, HOME: home, LANG: "en_US.UTF-8", LC_ALL: "", ...env },
  });

beforeAll(() => {
  root = mkdtempSync(path.join(tmpdir(), "cmux-guest-self-"));
  bin = path.join(root, "bin");
  home = path.join(root, "home");
  requestLog = path.join(root, "requests.log");
  mkdirSync(bin);
  mkdirSync(path.join(home, ".config", "cmux"), { recursive: true });
  writeFileSync(path.join(bin, "cmux"), GUEST_CMUX_SELF_SHIM);
  chmodSync(path.join(bin, "cmux"), 0o755);
  writeFileSync(
    path.join(home, ".config", "cmux", "model-plane.env"),
    "export CMUX_CODEROUTER_URL='https://coderouter.cmux.internal'\nexport OPENAI_API_KEY='cmux-vm-edge-placeholder'\n",
  );
});

afterAll(() => {
  rmSync(root, { recursive: true, force: true });
});

const withCurl = (body: string, status: string, fail = false) => {
  writeFileSync(path.join(bin, "curl"), fakeCurl(body, status, fail));
  chmodSync(path.join(bin, "curl"), 0o755);
  writeFileSync(requestLog, "");
};

describe("guest cmux self-discovery shim", () => {
  test("is valid POSIX sh and installs atomically to /usr/local/bin/cmux", () => {
    const syntax = spawnSync("/bin/sh", ["-n", path.join(bin, "cmux")], { encoding: "utf8" });
    expect(syntax.status).toBe(0);
    expect(GUEST_CMUX_SELF_SHIM.startsWith("#!/bin/sh\n")).toBe(true);
    const install = guestSelfCliInstallCommand();
    expect(install).toContain(`mv -f ${GUEST_CMUX_SELF_SHIM_PATH}.tmp.$$ ${GUEST_CMUX_SELF_SHIM_PATH}`);
    expect(install).toContain("base64 -d");
    expect(install).not.toContain("crt_");
  });

  test("cmux self prints this machine and calls the edge with the placeholder bearer", () => {
    withCurl(JSON.stringify(SELF_BODY), "200");
    const result = run(["self"]);
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("builder\tfs-self\trunning\t(this machine)\nteam\tteam-1\t2 machines\n");
    const request = spawnSync("cat", [requestLog], { encoding: "utf8" }).stdout;
    expect(request).toContain("https://coderouter.cmux.internal/api/vm/self");
    expect(request).toContain("authorization: Bearer cmux-vm-edge-placeholder");
    expect(request).not.toContain("crt_");
  });

  test("cmux self --json passes the body through unchanged", () => {
    withCurl(JSON.stringify(SELF_BODY), "200");
    const result = run(["self", "--json"]);
    expect(result.status).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual(SELF_BODY);
  });

  test("cmux vm ls lists the team's machines with this one marked", () => {
    withCurl(JSON.stringify(SELF_BODY), "200");
    const result = run(["vm", "ls"]);
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("  quiet-teal-otter\tfs-sibling\tpaused\n* builder\tfs-self\trunning\n");
    const json = run(["vm", "ls", "--json"]);
    expect(JSON.parse(json.stdout)).toEqual({ machines: SELF_BODY.machines });
  });

  test("the full guest CLI retains self discovery without requiring a daemon", () => {
    withCurl(JSON.stringify(SELF_BODY), "200");
    const fullCLI = path.join(bin, "cmux-full");
    writeFileSync(fullCLI, GUEST_CMUX_SHIM);
    for (const args of [["self", "--json"], ["vm", "ls", "--json"], ["vm", "list", "--json"]]) {
      const result = spawnSync("/bin/sh", [fullCLI, ...args], {
        encoding: "utf8",
        env: { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}`, HOME: home, CMUX_TUI_BIN: path.join(root, "absent-daemon") },
      });
      expect(result.status).toBe(0);
      expect(JSON.parse(result.stdout)).toEqual(args[0] === "self" ? SELF_BODY : { machines: SELF_BODY.machines });
    }
  });

  test("an unreachable edge exits 1 with the hostname and curl's reason", () => {
    withCurl("", "000", true);
    const result = run(["self"]);
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
    // Real curl prints its error line and then the --write-out status; the
    // reason shown is the error line, never the trailing "000".
    expect(result.stderr).toBe("cmux: cannot reach the cmux API from this machine (" + result.stderr.split("(")[1]?.split(")")[0] + "): curl: (6) Could not resolve host: coderouter.cmux.internal\n");
    expect(result.stderr).not.toContain("000");
  });

  test("a rejected machine exits 1 with the API's message", () => {
    withCurl(JSON.stringify({ error: "unauthorized", message: "This machine's cmux credential expired or was revoked." }), "401");
    const result = run(["vm", "ls"]);
    expect(result.status).toBe(1);
    expect(result.stderr).toBe("cmux: the cmux API rejected this machine (HTTP 401): This machine's cmux credential expired or was revoked.\n");
  });

  test("host-only verbs are refused with a pointer to the Mac CLI", () => {
    withCurl(JSON.stringify(SELF_BODY), "200");
    for (const args of [["vm", "new"], ["vm", "exec", "fs-self", "--", "ls"]]) {
      const result = run(args);
      expect(result.status).toBe(2);
      expect(result.stderr).toContain("runs on the Mac cmux CLI");
    }
    // notify belongs to the machine's daemon; without one installed the shim
    // says so instead of pointing at the Mac.
    const notify = run(["notify", "--title", "x"]);
    expect(notify.status).toBe(2);
    expect(notify.stderr).toContain("needs the cmux-tui daemon");
  });

  test("notify delegates to the daemon CLI with the machine's session socket", async () => {
    const fakeTui = path.join(root, "fake-cmux-tui");
    writeFileSync(fakeTui, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n", { mode: 0o755 });
    const runDir = path.join(root, "run");
    mkdirSync(runDir, { recursive: true });
    const sock = path.join(runDir, "cloud.sock");
    const server = createServer().listen(sock);
    await new Promise((resolve) => server.once("listening", resolve));
    try {
      // Outside a daemon terminal the shim points the CLI at the daemon's session socket.
      const outside = run(["notify", "--title", "x", "--subtitle", "y"], { CMUX_TUI_BIN: fakeTui, CMUX_TUI_RUN_DIR: runDir });
      expect(outside.status).toBe(0);
      expect(outside.stdout.split("\n").filter(Boolean)).toEqual(["--socket", sock, "notify", "--title", "x", "--subtitle", "y"]);
      // Inside a daemon terminal the injected socket already applies.
      const inside = run(["notification", "list"], { CMUX_TUI_BIN: fakeTui, CMUX_TUI_RUN_DIR: runDir, CMUX_TUI_SOCKET: "/tmp/injected.sock" });
      expect(inside.stdout.split("\n").filter(Boolean)).toEqual(["notification", "list"]);
    } finally {
      server.close();
    }
    expect(spawnSync("cat", [requestLog], { encoding: "utf8" }).stdout).toBe("");
    const help = run(["--help"]);
    expect(help.status).toBe(0);
    expect(help.stdout).toContain("cmux self [--json]");
    expect(run(["self", "--bogus"]).status).toBe(2);
  });

  test("speaks Japanese when the locale asks for it", () => {
    withCurl(JSON.stringify(SELF_BODY), "200");
    const result = run(["self"], { LANG: "ja_JP.UTF-8" });
    expect(result.stdout).toContain("(このマシン)");
    expect(run(["--help"], { LC_ALL: "ja_JP.UTF-8" }).stdout).toContain("cmux Cloud マシン内");
  });

  test("missing edge env exits 2 without any request", () => {
    withCurl(JSON.stringify(SELF_BODY), "200");
    const result = run(["self"], { HOME: root });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("CMUX_CODEROUTER_URL");
    expect(spawnSync("cat", [requestLog], { encoding: "utf8" }).stdout).toBe("");
  });
});

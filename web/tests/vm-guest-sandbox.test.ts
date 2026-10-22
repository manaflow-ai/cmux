import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";
import { GUEST_SANDBOX_STANDALONE } from "../services/vms/guestSandboxCli";
import { runChild } from "./helpers/run-child";

setDefaultTimeout(60_000);

const KEY = `cmuxvm_sk_${"a".repeat(43)}`;

// A fake curl: records each call (method, URL, headers, body) and answers like the cmux VM API.
const FAKE_CURL = `#!/bin/sh
out=""; method=GET; url=""; body=""; headers=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|--connect-timeout|--max-time) shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -H) headers="$headers|$2"; shift 2 ;;
    --data-binary) body="$(cat)"; shift 2 ;;
    -sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s %s %s %s\\n' "$method" "$url" "$headers" "$body" >> "$HOME/curl-calls"
polls="$(cat "$HOME/polls" 2>/dev/null || echo 0)"
case "$method $url" in
  "POST https://vm.test/v1/vms") printf '{"id":"vm_one","state":"starting"}' > "$out"; printf 201 ;;
  "GET https://vm.test/v1/vms/vm_one")
    echo $((polls + 1)) > "$HOME/polls"
    if [ "$polls" -ge 1 ]; then printf '{"id":"vm_one","state":"running"}' > "$out"; else printf '{"id":"vm_one","state":"starting"}' > "$out"; fi
    printf 200 ;;
  "GET https://vm.test/v1/vms") printf '{"items":[{"id":"vm_one","state":"running","displayName":"box"}]}' > "$out"; printf 200 ;;
  "POST https://vm.test/v1/vms/vm_one/exec") printf '{"exitCode":3,"stdout":"ubuntu\\\\n","stderr":"warn"}' > "$out"; printf 200 ;;
  "POST https://vm.test/v1/vms/vm_two/exec") printf '{"message":"VM not found","_tag":"NotFound"}' > "$out"; printf 404 ;;
  "DELETE https://vm.test/v1/vms/vm_one") : > "$out"; printf 204 ;;
  *) printf '{}' > "$out"; printf 500 ;;
esac
`;

async function runSandbox(args: string[], options: { readonly env?: Record<string, string>; readonly config?: { readonly mode: number } | null; readonly standalone?: boolean } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "cmux-guest-sandbox-"));
  writeFileSync(join(dir, "cmux"), options.standalone === true ? GUEST_SANDBOX_STANDALONE : GUEST_CMUX_SHIM);
  writeFileSync(join(dir, "curl"), FAKE_CURL);
  chmodSync(join(dir, "curl"), 0o755);
  writeFileSync(join(dir, "cmux-tui"), "#!/bin/sh\nexit 0\n");
  chmodSync(join(dir, "cmux-tui"), 0o755);
  if (options.config !== null) {
    mkdirSync(join(dir, ".config", "cmux"), { recursive: true });
    const file = join(dir, ".config", "cmux", "agent.json");
    writeFileSync(file, JSON.stringify({ key: KEY, apiUrl: "https://vm.test", keyId: "vmk_x", expiresAt: "2026-10-22T05:00:00Z", maxVms: 5, maxUsdPerHour: 2, labels: {} }));
    chmodSync(file, options.config?.mode ?? 0o600);
  }
  const result = await runChild("sh", [join(dir, "cmux"), ...(options.standalone === true ? [] : ["sandbox"]), ...args], {
    timeout: 30_000,
    env: { NODE_ENV: "test", HOME: dir, CMUX_TUI_BIN: join(dir, "cmux-tui"), PATH: `${dir}:${process.env.PATH ?? "/usr/bin:/bin"}`, ...options.env },
  });
  let calls = "";
  try {
    calls = readFileSync(join(dir, "curl-calls"), "utf8");
  } catch {}
  return { ...result, calls };
}

describe("cmux sandbox", () => {
  test("refuses to run without an agent key", async () => {
    const result = await runSandbox(["list"], { config: null });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("no agent key");
    expect(result.calls).toBe("");
  });

  test("refuses an agent.json other users can read", async () => {
    const result = await runSandbox(["list"], { config: { mode: 0o644 } });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("must be mode 0600");
    expect(result.calls).toBe("");
  });

  test("create sends the key and an idempotency key, waits until running and prints the id", async () => {
    const result = await runSandbox(["create", "--name", "box", "--vcpus", "2"]);
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe("vm_one");
    const [post] = result.calls.split("\n");
    expect(post).toContain("POST https://vm.test/v1/vms ");
    expect(post).toContain(`authorization: Bearer ${KEY}`);
    expect(post).toMatch(/idempotency-key: sandbox-[0-9a-f]{32}/);
    expect(post).toContain('{"displayName":"box","resources":{"vcpus":2}}');
    expect(result.calls.match(/GET https:\/\/vm.test\/v1\/vms\/vm_one/g)?.length).toBe(2);
  });

  test("exec prints the output and exits with the command's status", async () => {
    const result = await runSandbox(["exec", "vm_one", "--user", "ubuntu", "--", "whoami"]);
    expect(result.status).toBe(3);
    expect(result.stdout).toBe("ubuntu\n");
    expect(result.stderr).toBe("warn");
    expect(result.calls).toContain('{"command":"whoami","linuxUser":"ubuntu"}');
  });

  test("another agent's VM is the service's 404, not a crash", async () => {
    const result = await runSandbox(["exec", "vm_two", "--", "true"]);
    expect(result.status).toBe(4);
    expect(result.stderr).toContain("HTTP 404: VM not found");
  });

  test("CMUX_AGENT_KEY wins over the file, and list and delete use it", async () => {
    const other = `cmuxvm_sk_${"b".repeat(43)}`;
    const listed = await runSandbox(["list"], { env: { CMUX_AGENT_KEY: other } });
    expect(listed.stdout).toBe("vm_one\trunning\tbox\n");
    expect(listed.calls).toContain(`authorization: Bearer ${other}`);
    const deleted = await runSandbox(["delete", "vm_one"]);
    expect(deleted.status).toBe(0);
    expect(deleted.calls).toContain("DELETE https://vm.test/v1/vms/vm_one");
  });

  test("the standalone cmux-sandbox script takes the same verbs and a per-agent config path", async () => {
    const result = await runSandbox(["list"], { standalone: true, config: null, env: { CMUX_AGENT_KEY: KEY, CMUX_VM_API_URL: "https://vm.test" } });
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("vm_one\trunning\tbox\n");
    const missing = await runSandbox(["list"], { standalone: true, config: null, env: { CMUX_AGENT_CONFIG: "/nonexistent/agents/a1.json" } });
    expect(missing.status).toBe(2);
    expect(missing.stderr).toContain("no agent key");
  });

  test("rejects a non-https API URL and a malformed VM id", async () => {
    expect((await runSandbox(["list"], { env: { CMUX_VM_API_URL: "http://vm.test" } })).status).toBe(2);
    const bad = await runSandbox(["delete", "not-a-vm"]);
    expect(bad.status).toBe(2);
    expect(bad.calls).toBe("");
  });
});

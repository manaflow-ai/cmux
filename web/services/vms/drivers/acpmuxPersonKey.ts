import { cmuxTuiAsDaemonUser, cmuxTuiLayoutSelector } from "./cmuxTuiDaemon";

// The fixed guest commands of the keyed acpmux start on a Cloud machine
// (cx-0q7o slice 2d, cx-psxg; acpmux hub/person.rs). The app makes the
// person key K and sends it to the backend; the backend gives it to the
// machine only as the stdin of `acp --json daemon start --person-key-fd 0`.
// No command here takes anything from the caller: K arrives on stdin, the
// person_holds nonce is checked hex before it is put into a frame.
//
// Every command runs as root through the provider exec, then as the
// daemon's own user, home and environment (cmuxTuiLayoutSelector,
// cmuxTuiAsDaemonUser), so the acpmux it starts, and the `acp stdio` that
// checks it, use the socket the session daemon's agent-session-* verbs use.
// The environment is the host unit's `Environment=` (cmux-host.service, or
// cmux-tui-daemon.service on older images), the same one the session
// daemon's own acpmux starter passes on (agent tools, browser host, PATH).

/** Exit status of a command that refuses a team machine (the agent-session-start team_vm_blocked rule, cx-d0tq). */
export const ACPMUX_EXIT_TEAM_VM = 81;
/** Exit status of a prepare on a machine whose cmux-tui has no keyed start. */
export const ACPMUX_EXIT_UNSUPPORTED = 82;
/**
 * The guest kills a keyed start or a person_holds check after this long.
 * Under the provider's 5 s background window, so the call that carries the
 * key is never one the provider stores (the driver also sends no background
 * header); a start that needs longer fails as a timeout instead.
 */
export const ACPMUX_STDIN_EXEC_TIMEOUT_MS = 4_500;
/** The shutdown with agent handoff of the prepare step (no stdin). */
export const ACPMUX_PREPARE_TIMEOUT_MS = 75_000;

const HOST_UNITS = ["cmux-host.service", "cmux-tui-daemon.service"] as const;

/**
 * A team machine refuses (the cmux-tui agent_start_host.rs markers, read as
 * root here: kind `team` in /etc/cmux/vm-kind, or the team files root
 * /srv/team). Root-owned; a planted marker can only make it refuse.
 */
function teamMachineCheck(): string {
  return (
    `cmux_kind="$(head -c 64 /etc/cmux/vm-kind 2>/dev/null | tr -d '[:space:]')"; ` +
    `if [ "$cmux_kind" = team ] || [ -e /srv/team ]; then echo "cmux: this is a team machine" >&2; exit ${ACPMUX_EXIT_TEAM_VM}; fi`
  );
}

/** Exports the host unit's `Environment=` assignments (values carry no spaces, agent-tools.ts daemonEnvLines). */
function hostUnitEnvironment(): string {
  return (
    `set -f; cmux_unit_env=""; for cmux_unit in ${HOST_UNITS.join(" ")}; do ` +
    `cmux_unit_env="$(systemctl show -p Environment --value "$cmux_unit" 2>/dev/null || true)"; ` +
    `[ -n "$cmux_unit_env" ] && break; done; ` +
    `for cmux_kv in $cmux_unit_env; do case "$cmux_kv" in [A-Za-z_]*=*) export "$cmux_kv" ;; esac; done; set +f`
  );
}

/** Layout, team refusal and environment, with stdin closed so nothing here can read the key. */
function setup(): string {
  return `{ ${cmuxTuiLayoutSelector()} && ${teamMachineCheck()} && ${hostUnitEnvironment()}; } </dev/null`;
}

/**
 * Step 1, no stdin: refuse a cmux-tui without `--person-key-fd` BEFORE the
 * running daemon stops, then stop it and hand its agents to the next run
 * (`daemon shutdown --keep-agents`; no daemon running is not an error).
 */
export function acpmuxPrepareCommand(): string {
  const help = cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" acp daemon start --help`);
  const shutdown = cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" acp daemon shutdown --keep-agents`);
  return [
    setup(),
    `{ ${help}; } </dev/null 2>&1 | grep -q -e '--person-key-fd' || { echo "cmux: this machine's cmux-tui has no keyed start" >&2; exit ${ACPMUX_EXIT_UNSUPPORTED}; }`,
    `{ ${shutdown}; } </dev/null >/dev/null 2>&1 || true`,
    "echo prepared",
  ].join(" && ");
}

/**
 * Step 2, stdin = K (64 lowercase hex and a newline): the keyed start. Only
 * the last command has the exec's stdin; it prints acpmux's status JSON
 * (`personKey`, `personInstance`).
 */
export function acpmuxKeyedStartCommand(): string {
  return `${setup()} && ${cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" acp --json daemon start --person-key-fd 0`, { exec: true })}`;
}

/** `_acpmux/person_holds` over `acp stdio`; stdin = {@link acpmuxPersonHoldsFrames}. */
export function acpmuxPersonHoldsCommand(): string {
  return `${setup()} && ${cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" acp stdio`, { exec: true })}`;
}

const HEX64 = /^[0-9a-f]{64}$/;

/** Whether `nonce` is a person_holds nonce (64 lowercase hex characters). */
export function isAcpmuxNonce(nonce: unknown): nonce is string {
  return typeof nonce === "string" && HEX64.test(nonce);
}

/** The frames of the person_holds check (as SSHService+PersonKey.swift sends them). */
export function acpmuxPersonHoldsFrames(nonce: string): string {
  if (!isAcpmuxNonce(nonce)) throw new Error("acpmux person_holds nonce must be 64 lowercase hex characters");
  return [
    JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } }),
    JSON.stringify({ jsonrpc: "2.0", id: 2, method: "_acpmux/person_holds", params: { nonce } }),
    "",
  ].join("\n");
}

/** Whether `bytes` is one person key line: 64 lowercase hex characters and a newline. */
export function isAcpmuxKeyLine(bytes: Uint8Array): boolean {
  if (bytes.byteLength !== 65 || bytes[64] !== 0x0a) return false;
  for (let i = 0; i < 64; i += 1) {
    const b = bytes[i]!;
    if (!((b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66))) return false;
  }
  return true;
}

/** Text that came back from the guest, with every 64-hex run removed and bounded. */
export function redactGuestLine(text: string): string | undefined {
  const line = text.split("\n").map((l) => l.trim()).filter(Boolean).at(-1);
  if (!line) return undefined;
  return line.replace(/[0-9a-fA-F]{64,}/g, "[redacted]").replace(/[A-Za-z0-9+/]{80,}={0,2}/g, "[redacted]").slice(0, 300);
}

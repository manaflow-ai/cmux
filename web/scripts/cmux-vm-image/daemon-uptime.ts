/**
 * Smoke check: the session host stays up after boot and after one forced rebind (smoke.ts).
 *
 * Bake run 41701438675 passed 28 checks on an image whose session host crash-looped after any
 * rebind: cmux-host's bind kept `lifecycle-fence.json` but dropped `auth/`, and cmux-tui refuses
 * that shape at startup ("previous remote daemon authorization state requires explicit
 * migration; verify that no legacy cmux-tui process remains"), so the Native receiver never bound
 * UDP 4101 (fixed in cmux#34128). Every check ran once, right after the first bind, which was clean.
 *
 * Each phase holds for HOLD_SECONDS and needs: the same session host pid alive at both ends, no
 * session dir with a lifecycle fence but no `auth/`, no legacy or migration error and no session
 * host exit in the host unit's journal during the hold, and UDP 4101 bound once the clone is bound
 * to Cloud (`/var/lib/cmux/bound.json`; the Native receiver binds only after a Cloud bind, which a
 * smoke clone never gets, so there the port is reported and not required).
 *
 * The forced rebind is the bind agent's own path: a different id in /etc/cmux/daemon-instance-id
 * and a write of the driver file (/run/cmux/instance-id) wake cmux-host, which reads the instance
 * id, sees it unbound, stops the session host, drops the remote identity, writes the id back and
 * starts a new session host.
 */
import { DEVBOX_WORK_HOME } from "../../services/vms/images/workUser";
import { DEVBOX_INSTANCE_ID_COMMAND } from "../devbox-image-common";
import { HOST_UNIT } from "./host-agent";

export const HOLD_SECONDS = 60;
const SESSION_HOST_PID = "pgrep -f 'cmux-tui server [s]tart' | head -1";
const REMOTE_SESSIONS = `${DEVBOX_WORK_HOME}/.local/state/cmux/remote/sessions`;
/** cmux-tui's refusal of a fenced session without `auth/` (remote_runtime.rs) and any like it. */
const LEGACY_ERROR = "grep -iE 'legacy|migration' | grep -iE 'error|requires|refus|fail|cannot'";

/** One hold: prints `key=value` lines for daemonUptimeProblems. */
export function daemonHoldCommand(holdSeconds = HOLD_SECONDS): string {
  return [
    // A second past whatever came before (the rebind's own intended stop), so the journal window holds only the hold.
    "sleep 1",
    "t0=$(date +%s)",
    `pid=$(${SESSION_HOST_PID})`,
    'echo "pid=$pid"',
    `sleep ${holdSeconds}`,
    'if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo alive=1; else echo alive=0; fi',
    `echo "pid-after=$(${SESSION_HOST_PID})"`,
    "echo \"udp4101=$(ss -Hulpn 'sport = :4101' 2>/dev/null | wc -l)\"",
    "if [ -e /var/lib/cmux/bound.json ]; then echo cloud-bound=1; else echo cloud-bound=0; fi",
    `for d in ${REMOTE_SESSIONS}/*/; do [ -e "$d/lifecycle-fence.json" ] && [ ! -d "$d/auth" ] && echo "fence-without-auth=$d"; done`,
    `journalctl -u ${HOST_UNIT} --since "@$t0" --no-pager -o cat 2>/dev/null > /root/cmux-uptime.log`,
    `${LEGACY_ERROR} < /root/cmux-uptime.log | head -3 | cut -c1-200 | sed 's/^/legacy-error=/'`,
    "grep -E 'session host [0-9]+ exited' /root/cmux-uptime.log | head -3 | cut -c1-200 | sed 's/^/host-exit=/'",
    "rm -f /root/cmux-uptime.log",
    "true",
  ].join("; ");
}

/** The forced rebind; prints `rebound=1` once the id is back and a new session host runs. */
export function forcedRebindCommand(): string {
  return [
    `inst=$(${DEVBOX_INSTANCE_ID_COMMAND})`,
    `old=$(${SESSION_HOST_PID})`,
    'test -n "$inst" || { echo rebound=0; echo "detail=no instance id"; exit 0; }',
    "printf 'vm-smoke-forced-rebind\\n' > /etc/cmux/daemon-instance-id",
    "touch /run/cmux/instance-id",
    // Test-side wait (bounded); the agent itself is event driven.
    `for i in $(seq 1 300); do p=$(${SESSION_HOST_PID}); [ "$(cat /etc/cmux/daemon-instance-id 2>/dev/null)" = "$inst" ] && [ -n "$p" ] && [ "$p" != "$old" ] && break; sleep 0.2; done`,
    `p=$(${SESSION_HOST_PID})`,
    'if [ "$(cat /etc/cmux/daemon-instance-id 2>/dev/null)" = "$inst" ] && [ -n "$p" ] && [ "$p" != "$old" ]; then echo rebound=1; else echo rebound=0; fi',
    'echo "detail=old pid $old, new pid ${p:-none}, bound $(cat /etc/cmux/daemon-instance-id 2>/dev/null)"',
  ].join("; ");
}

function lines(stdout: string): Array<[string, string]> {
  return stdout
    .trim()
    .split("\n")
    .filter((l) => l.includes("="))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]);
}

/** Problems with one daemonHoldCommand answer; `nativeReceiver` requires UDP 4101 on a Cloud-bound clone. */
export function daemonUptimeProblems(stdout: string, nativeReceiver: boolean): string[] {
  const kv = lines(stdout);
  const get = (key: string) => kv.find(([k]) => k === key)?.[1] ?? "";
  const problems: string[] = [];
  const pid = get("pid");
  if (!pid) problems.push("no session host at the start of the hold");
  else if (get("alive") !== "1" || get("pid-after") !== pid) problems.push(`session host ${pid} did not stay up ${HOLD_SECONDS} s (now ${get("pid-after") || "none"})`);
  for (const [k, v] of kv) {
    if (k === "fence-without-auth") problems.push(`lifecycle fence without auth/: ${v}`);
    if (k === "legacy-error") problems.push(`legacy or migration error: ${v}`);
    if (k === "host-exit") problems.push(`session host exited: ${v}`);
  }
  if (nativeReceiver && get("cloud-bound") === "1" && Number(get("udp4101")) < 1) problems.push("UDP 4101 not bound on a Cloud-bound Native receiver clone");
  return problems;
}

export function daemonUptimeDetail(stdout: string): string {
  const kv = Object.fromEntries(lines(stdout));
  const udp = kv["cloud-bound"] === "1" ? `udp4101 sockets ${kv.udp4101}` : `udp4101 sockets ${kv.udp4101} (not required: clone not bound to Cloud)`;
  return `session host ${kv.pid} up ${HOLD_SECONDS} s; ${udp}`;
}

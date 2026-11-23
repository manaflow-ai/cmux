/** Read-only evidence from the guest's existing Rust updater. Never runs update check/adopt. */
export const GUEST_UPDATER_DIAGNOSTICS = `python3 - <<'CMUX_GUEST_DIAGNOSTICS'
import json, os, subprocess

def read(argv):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=2)
        return {"code": r.returncode, "stdout": r.stdout[:32768]}
    except (OSError, subprocess.TimeoutExpired):
        return {"code": None}

units = {}
for unit in ["cmux-host.service", "cmux-tui-daemon.service"]:
    units[unit] = read(["systemctl", "show", unit, "--property=LoadState,ActiveState,MainPID,ExecStart"])
    fields = dict(line.split("=", 1) for line in units[unit].get("stdout", "").splitlines() if "=" in line)
    pid = fields.get("MainPID", "")
    if pid.isdigit() and pid != "0":
        prefix = [] if os.geteuid() == 0 else ["sudo", "-n"]
        units[unit]["executable"] = read(prefix + ["readlink", "-f", "/proc/" + pid + "/exe"])
store = read(["readlink", "-f", "/opt/cmux/current"])
versions = {name: read([name, "--version"]) for name in ["cmux-tui", "acpmux"]}
# Reading as an unprivileged user can silently default missing root-owned updater state.
# Refuse that incomplete read if noninteractive sudo is unavailable; never ask for a password.
host = "/opt/cmux/current/bin/cmux"
if not os.path.exists(host):
    host = os.path.expanduser("~/.cmux/bin/cmux-tui")
prefix = [] if os.geteuid() == 0 else ["sudo", "-n"]
status = read(prefix + [host, "host", "update", "status", "--json"])
print(json.dumps({"units": units, "store": store, "versions": versions, "updater": status}))
CMUX_GUEST_DIAGNOSTICS`;

type Exec = (command: string, timeoutMs?: number) => Promise<{ code: number; stdout: string; stderr: string }>;
type Json = Record<string, any>;
const unavailable = "unavailable";
const object = (v: unknown): Json => v !== null && typeof v === "object" && !Array.isArray(v) ? v : {};
const number = (v: unknown) => typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : unavailable;
const hash = (v: unknown) => typeof v === "string" && /^[a-f0-9]{12,64}$/.test(v) ? v : unavailable;
const choice = (v: unknown, values: string[]) => typeof v === "string" && values.includes(v) ? v : unavailable;
const safePath = (v: unknown): string => typeof v === "string" && /^(?:\/opt\/cmux\/(?:profiles\/[0-9]+|current|store\/[a-f0-9]{64})(?:\/(?:bin\/)?(?:cmux|cmux-tui|acpmux))?|\/usr\/local\/(?:bin|libexec)\/cmux-devbox-boot|\/home\/cmux\/\.cmux\/bin\/cmux-tui)$/.test(v) ? v : unavailable;
const output = (v: unknown): string | null => {
  const row = object(v);
  return row.code === 0 && typeof row.stdout === "string" && row.stdout.length <= 32768 ? row.stdout.trim() : null;
};
const parse = (s: string | null): Json => { try { return object(JSON.parse(s ?? "")); } catch { return {}; } };

/** Do not retain arbitrary argv, updater error text (state.last), environment, or unknown fields. */
export function guestDiagnosticsFacts(raw: unknown) {
  const row = object(raw);
  const units = Object.fromEntries(["cmux-host.service", "cmux-tui-daemon.service"].map((name) => {
    const text = output(object(row.units)[name]);
    const fields = Object.fromEntries((text ?? "").split("\n").map((s) => { const i = s.indexOf("="); return [s.slice(0, i), s.slice(i + 1)]; }));
    const start = fields.ExecStart ?? "";
    const argv = start.match(/argv\[\]=(.*?);/)?.[1].trim().split(/\s+/);
    return [name, {
      load: choice(fields.LoadState, ["loaded", "not-found", "masked", "error"]),
      active: choice(fields.ActiveState, ["active", "inactive", "failed", "activating", "deactivating", "reloading"]),
      pid: fields.MainPID && /^\d+$/.test(fields.MainPID) ? number(Number(fields.MainPID)) : unavailable,
      executable: safePath(output(object(object(row.units)[name]).executable)),
      exec_start: { path: safePath(start.match(/path=([^ ;]+)/)?.[1]),
        argv: argv?.map((s) => safePath(s) !== unavailable ? s : ["host", "run", "--mode", "system"].includes(s) ? s : "[redacted]") ?? unavailable },
    }];
  }));
  const versions = Object.fromEntries(["cmux-tui", "acpmux"].map((name) => {
    const text = output(object(row.versions)[name]);
    // Keep only the version and build identity, not arbitrary version command output.
    const match = text?.match(/^(?:cmux|acpmux) ([0-9]+\.[0-9]+\.[0-9]+) \(([a-f0-9]{7,40})(?:[ ;)]|$)/);
    return [name, match ? { version: match[1], commit: match[2] } : unavailable];
  }));
  const status = parse(output(row.updater));
  const state = object(status.state), look = object(state.look), first = object(state.first_ready);
  const codes = ["current", "older", "rolled-back-before", "held", "busy", "swapped", "off", "failed"];
  const reasons = ["connect-hold", "resume-hold", "turn", "carrier", "unread", "carrier+turn", "turn+unread", "carrier+unread", "carrier+turn+unread"];
  const swap = (v: unknown) => { const x = object(v); return { commit: hash(x.commit), at: number(x.at), outcome: choice(x.outcome, ["updated", "rolled_back"]) }; };
  return {
    supervisor: units, store_link: safePath(output(row.store)), versions,
    updater: {
      status: Object.keys(status).length ? "available" : unavailable,
      off: status.off === null ? false : typeof status.off === "string" ? true : unavailable,
      off_reason: status.off === "/etc/cmux/no-self-update exists" ? "no-self-update" :
        typeof status.off === "string" && status.off.startsWith("/home/cmux/.cmux/bin/cmux-tui ") ? "work-link-replaced" : unavailable,
      current_generation: number(status.current), cmux_tui_sha256: hash(status.cmux_tui),
      applied_commit: hash(state.applied_commit), applied_committed_at: number(state.applied_committed_at),
      last_at: number(state.last_at),
      look: { outcome: choice(look.outcome, codes), reason: choice(look.reason, reasons), at: number(look.at),
        seen_at: number(look.seen_at), waited: choice(look.waited, reasons.flatMap((r) => [`held:${r}`, `busy:${r}`])),
        swapped: swap(look.swapped), settled: swap(look.settled) },
      first_ready: { status: Object.keys(first).length ? "available" : unavailable,
        image_behind: typeof first.image_behind === "boolean" ? first.image_behind : unavailable,
        from_version: hash(first.from_version), to_version: hash(first.to_version), channel_commit: hash(first.channel_commit),
        started_at: number(first.started_at), finished_at: number(first.finished_at), check_ms: number(first.check_ms),
        update_ms: number(first.update_ms), outcome: choice(first.outcome, ["updated", "current", "on_image"]) },
      pending: status.pending === null ? null : { commit: hash(object(status.pending).commit), started_at: number(object(status.pending).started_at) },
    },
  };
}

export type GuestDiagnostics = Awaited<ReturnType<typeof collectGuestDiagnostics>>;
export async function collectGuestDiagnostics(exec: Exec | null, phase: "journey-facts" | "before-cleanup", timeoutMs = 18_000, signal?: AbortSignal) {
  const started = Date.now();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let facts = guestDiagnosticsFacts(null);
  let reason: string | null = "no exec route";
  let abort: (() => void) | undefined;
  if (exec) {
    try {
      if (signal?.aborted) throw new Error("cancelled");
      const result = await Promise.race([exec(GUEST_UPDATER_DIAGNOSTICS, Math.max(1, timeoutMs - 1_000)), new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("deadline")), timeoutMs);
        abort = () => reject(new Error("cancelled"));
        signal?.addEventListener("abort", abort, { once: true });
      })]);
      if (result.code !== 0) reason = "guest diagnostic command unavailable";
      else {
        const raw = parse(result.stdout.length <= 131072 ? result.stdout : null);
        reason = Object.keys(raw).length ? null : "guest diagnostic output unavailable";
        facts = guestDiagnosticsFacts(raw);
      }
    } catch { reason = "guest exec failed or timed out"; }
    finally { clearTimeout(timer); if (abort) signal?.removeEventListener("abort", abort); }
  }
  return { phase, collected_at: new Date(started).toISOString(), duration_ms: Date.now() - started,
    status: reason === null ? "collected" : unavailable, reason, ...facts };
}

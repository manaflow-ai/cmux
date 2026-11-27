import { isIP } from "node:net";
import { CMUX_TUI_PORT, cmuxTuiAsDaemonUser, cmuxTuiLayoutSelector } from "./drivers/cmuxTuiDaemon";

/**
 * Idle auto-pause for Cloud machines (pilot blocker 1a). A 4 vCPU / 8 GB
 * machine costs about $0.26/h until someone pauses it, and Freestyle's own
 * idle timer is off on every machine (FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS):
 * it counts only network and exec traffic, so it would pause a machine whose
 * agent is mid-turn and quiet. The server decides instead, from what the
 * machine itself runs:
 *
 * - the `vm-idle-pause` cron (every 5 minutes) runs {@link vmIdleProbeCommand}
 *   on each running machine through the provider's exec, the same exec the
 *   resource sampler uses (read-only; nothing is installed or started);
 * - {@link decideVmIdlePause} calls the machine idle only when the probe shows
 *   no person's input through an attached client for the whole timeout (an
 *   attached app by itself is not activity: the Mac app stays attached for
 *   days and re-attaches after every daemon restart), no ssh login, no agent
 *   turn or sub-session running (the
 *   daemon's live agents and every acpmux session with a turn or a pending
 *   permission), no terminal running a foreground command (a build, a server
 *   started by hand, vim, an agent CLI), and no inbound connection on the
 *   machine's private address (a forwarded port in use; the app's own link
 *   to the daemon port does not count), no CPU use above
 *   {@link VM_IDLE_CPU_BUSY_CORES} since the previous probe (a `nohup make`,
 *   a container, a systemd unit), and no exec, files or attach call through
 *   the API within the timeout ({@link VM_LAST_API_ACTIVITY_KEY});
 * - only after every probe for the whole timeout said idle does the machine
 *   pause, through the same pause path the Pause Machine action uses
 *   (workflows.ts pauseVm), with pause reason `idle`.
 *
 * Anything the probe cannot read (an old image, a daemon that does not
 * answer, a failed exec, a row without a private address) is unknown, and
 * unknown never pauses.
 */

/**
 * Minutes of idleness before a machine without its own setting pauses. The
 * single switch for the default: 0 turns auto-pause off for every machine that
 * has not chosen a value. Leo, 2026-10-21: on, 30 minutes. Leo, 2026-10-30:
 * "we're saying no auto pausing of the freestyle vms for now": Off.
 */
export const VM_IDLE_PAUSE_DEFAULT_MINUTES = 0;

/**
 * The kill switch for idle auto-pause, off unless the deployment sets
 * `CMUX_VM_IDLE_AUTO_PAUSE=on`. Off, the `vm-idle-pause` cron probes and
 * pauses no machine, not even one that chose a timeout (Leo, 2026-10-30:
 * "we're saying no auto pausing of the freestyle vms for now"). Pause Machine
 * and Resume are not affected.
 */
export function vmIdleAutoPauseEnabled(env: Readonly<Record<string, string | undefined>> = process.env): boolean {
  return env.CMUX_VM_IDLE_AUTO_PAUSE === "on";
}

/** The per-machine choices, in minutes; 0 is Off. */
export const VM_IDLE_PAUSE_CHOICES = [0, 15, 30, 60, 120] as const;
export type VmIdlePauseMinutes = (typeof VM_IDLE_PAUSE_CHOICES)[number];

/** providerMetadata keys; control-plane state, never written by a driver. */
export const VM_IDLE_PAUSE_MINUTES_KEY = "cmuxIdlePauseMinutes";
export const VM_IDLE_OBSERVATION_KEY = "cmuxIdleObservation";
export const VM_PAUSE_REASON_KEY = "cmuxPauseReason";
/** When a person last used the machine through the API (exec, files, attach), epoch ms. */
export const VM_LAST_API_ACTIVITY_KEY = "cmuxLastApiActivityAt";
/** When the idle cron last checked the machine, epoch ms; the cron checks the least recent first. */
export const VM_IDLE_PROBED_AT_KEY = "cmuxIdleProbedAt";

/** API activity is written at most this often per machine. */
export const VM_API_ACTIVITY_MIN_INTERVAL_MS = 60_000;

/**
 * CPU use, in cores averaged over the time between two probes, at or above
 * which the machine is busy. An idle machine (the cmux-tui daemon and acpmux
 * waiting) stays well under it; one core of a build is 20 times over.
 */
export const VM_IDLE_CPU_BUSY_CORES = 0.05;

/** Why the control plane paused a machine: the idle timer, or a person or client asking. */
export type VmPauseReason = "idle" | "user";

/** The cron's period (vercel.json `/api/cron/vm-idle-pause`). */
export const VM_IDLE_PROBE_INTERVAL_MS = 5 * 60_000;
/**
 * A previous idle observation older than this does not carry: the machine was
 * paused, the cron missed runs, or the probe failed in between, so nothing
 * vouches for the time since. Two missed runs and some slack.
 */
export const VM_IDLE_OBSERVATION_MAX_GAP_MS = 12 * 60_000;
/** The guest kills the probe after this; the cron bounds the whole exec a little above it. */
export const VM_IDLE_PROBE_TIMEOUT_MS = 15_000;

export function isVmIdlePauseMinutes(value: unknown): value is VmIdlePauseMinutes {
  return typeof value === "number" && (VM_IDLE_PAUSE_CHOICES as readonly number[]).includes(value);
}

type MetadataRow = { readonly providerMetadata?: Record<string, unknown> | null };

/** The machine's own choice, else the default. A stored value outside the choices is ignored. */
export function vmIdlePauseMinutesFromRow(row: MetadataRow): VmIdlePauseMinutes {
  const stored = row.providerMetadata?.[VM_IDLE_PAUSE_MINUTES_KEY];
  return isVmIdlePauseMinutes(stored) ? stored : VM_IDLE_PAUSE_DEFAULT_MINUTES;
}

/** Why a paused machine is paused, when the control plane paused it; null otherwise. */
export function vmPauseReasonFromRow(row: MetadataRow & { readonly status: string }): VmPauseReason | null {
  if (row.status !== "paused") return null;
  const stored = row.providerMetadata?.[VM_PAUSE_REASON_KEY];
  return stored === "idle" || stored === "user" ? stored : null;
}

/**
 * The first probe of the current idle stretch, and the last probe that saw it
 * with its busy CPU time (absent when that probe could not read it).
 */
export type VmIdleObservation = {
  readonly providerVmId: string;
  readonly idleSince: number;
  readonly observedAt: number;
  readonly cpuBusyMs?: number;
};

export function vmIdleObservationFromRow(row: MetadataRow & { readonly providerVmId?: string | null }): VmIdleObservation | null {
  const stored = row.providerMetadata?.[VM_IDLE_OBSERVATION_KEY];
  if (!stored || typeof stored !== "object" || Array.isArray(stored)) return null;
  const { providerVmId, idleSince, observedAt, cpuBusyMs } = stored as Record<string, unknown>;
  if (typeof providerVmId !== "string" || providerVmId !== row.providerVmId) return null;
  if (!isTime(idleSince) || !isTime(observedAt) || idleSince > observedAt) return null;
  return { providerVmId, idleSince, observedAt, ...(isCpuMs(cpuBusyMs) ? { cpuBusyMs } : {}) };
}

/** The last exec, files or attach call through the API, epoch ms; null when none is stored. */
export function vmLastApiActivityFromRow(row: MetadataRow): number | null {
  const stored = row.providerMetadata?.[VM_LAST_API_ACTIVITY_KEY];
  return isTime(stored) ? stored : null;
}

/**
 * The machine's private addresses (providerMetadata networkIpv4/networkIpv6).
 * Without one the probe cannot tell the app's link into the machine from
 * nothing, so the machine is unknown and never pauses.
 */
export function vmIdlePrivateAddressesFromRow(row: MetadataRow): string[] {
  const metadata = row.providerMetadata ?? {};
  const raw = [metadata["networkIpv4"], metadata["networkIpv6"]];
  // A malformed field can hide an inbound connection on that interface.
  if (raw.some((a) => a != null && a !== "" && (typeof a !== "string" || isIP(a) === 0))) return [];
  return raw.filter((a): a is string => typeof a === "string" && a !== "");
}

/** What {@link vmIdleProbeCommand} saw on the machine. */
export type VmIdleProbe = {
  /** The session daemon's activity snapshot; null when it did not answer. */
  readonly daemon: {
    readonly attachedClients: number;
    readonly liveAgents: number;
    readonly lastUserInputAt: number | null;
    readonly lastAgentActionAt: number | null;
  } | null;
  /** acpmux sessions; null when they could not be read (a stopped acpmux reads as none). */
  readonly acpmux: { readonly busySessions: number; readonly lastUpdatedAt: number | null } | null;
  /** Terminals whose foreground process group is not just a shell at its prompt. */
  readonly busyTerminals: number;
  /** Authenticated ssh sessions (an `sshd: user@…` process). */
  readonly sshSessions: number;
  /** Established TCP connections into the machine's private address, or into sshd. */
  readonly inboundConnections: number;
  /** CPU time spent busy since boot (user, nice, system, irq, softirq), ms; absent or null when unreadable. */
  readonly cpuBusyMs?: number | null;
};

/** The probe's JSON line (its last stdout line); null for anything malformed. */
export function parseVmIdleProbe(stdout: string): VmIdleProbe | null {
  const line = stdout.trim().split("\n").at(-1);
  if (!line) return null;
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return null;
  }
  if (!raw || typeof raw !== "object" || (raw as { v?: unknown }).v !== 1) return null;
  const v = raw as Record<string, unknown>;
  const busyTerminals = count(v.busy_terminals);
  const sshSessions = count(v.ssh_sessions);
  const inboundConnections = count(v.inbound_connections);
  if (busyTerminals === null || sshSessions === null || inboundConnections === null) return null;
  return {
    daemon: parseDaemon(v.daemon),
    acpmux: parseAcpmux(v.acpmux),
    busyTerminals,
    sshSessions,
    inboundConnections,
    // Older probes print no CPU field; that is no CPU verdict, not a malformed line.
    ...(isCpuMs(v.cpu_busy_ms) ? { cpuBusyMs: v.cpu_busy_ms } : {}),
  };
}

function parseDaemon(value: unknown): VmIdleProbe["daemon"] {
  if (!value || typeof value !== "object") return null;
  const d = value as Record<string, unknown>;
  const attachedClients = count(d.attached_clients);
  const liveAgents = count(d.live_agents);
  if (attachedClients === null || liveAgents === null) return null;
  return {
    attachedClients,
    liveAgents,
    lastUserInputAt: isTime(d.last_user_input_at_ms) ? d.last_user_input_at_ms : null,
    lastAgentActionAt: isTime(d.last_agent_action_at_ms) ? d.last_agent_action_at_ms : null,
  };
}

function parseAcpmux(value: unknown): VmIdleProbe["acpmux"] {
  if (!value || typeof value !== "object") return null;
  const a = value as Record<string, unknown>;
  const busySessions = count(a.busy_sessions);
  if (busySessions === null) return null;
  return { busySessions, lastUpdatedAt: isTime(a.last_updated_at_ms) ? a.last_updated_at_ms : null };
}

export type VmIdleDecision = {
  readonly pause: boolean;
  /** `off`, `unknown:<what>`, `active:<what>[,<what>]`, `idle` or `idle_timeout`; for logs and tests. */
  readonly reason: string;
  /** What to store for the next run; null clears it. */
  readonly observation: VmIdleObservation | null;
};

/**
 * The idle decision. `minutes` 0 never pauses. A row without a private
 * address, or an unknown or active probe, clears the observation. An idle
 * probe starts the idle stretch, or continues it when the previous
 * observation is recent enough to vouch for the time in between; the machine
 * pauses once the stretch, and every activity time (a person's input, an
 * agent action, an acpmux session change, an API call; never later than now),
 * are at least `minutes` old.
 */
export function decideVmIdlePause(input: {
  readonly providerVmId: string;
  readonly minutes: number;
  readonly probe: VmIdleProbe | null;
  readonly previous: VmIdleObservation | null;
  readonly now: number;
  /** The last exec, files or attach call through the API ({@link vmLastApiActivityFromRow}). */
  readonly lastApiActivityAt?: number | null;
  /** False when the row has no private address ({@link vmIdlePrivateAddressesFromRow}); the cron always passes it. */
  readonly privateAddressKnown?: boolean;
}): VmIdleDecision {
  const { now } = input;
  if (!(input.minutes > 0)) return { pause: false, reason: "off", observation: null };
  if (input.privateAddressKnown === false) return { pause: false, reason: "unknown:address", observation: null };
  const probe = knownProbe(input.probe);
  if (typeof probe === "string") return { pause: false, reason: `unknown:${probe}`, observation: null };
  const previous = carriedObservation(input.previous, input.providerVmId, now);
  const cpu = cpuCoresSince(previous, probe, now);
  const active = activeReasons(probe, cpu);
  if (active.length > 0) return { pause: false, reason: `active:${active.join(",")}`, observation: null };
  // A counter that went back (a reboot) vouches for nothing before it.
  const idleSince = previous !== null && cpu !== "reset" ? previous.idleSince : now;
  const reported = [probe.daemon.lastUserInputAt, probe.daemon.lastAgentActionAt, probe.acpmux.lastUpdatedAt, input.lastApiActivityAt]
    .filter((at): at is number => typeof at === "number")
    .map((at) => Math.min(at, now));
  const lastActivity = Math.max(idleSince, ...reported);
  const observation: VmIdleObservation = {
    providerVmId: input.providerVmId,
    idleSince,
    observedAt: now,
    ...(isCpuMs(probe.cpuBusyMs) ? { cpuBusyMs: probe.cpuBusyMs } : {}),
  };
  if (now - lastActivity >= input.minutes * 60_000) return { pause: true, reason: "idle_timeout", observation };
  return { pause: false, reason: "idle", observation };
}

type KnownVmIdleProbe = VmIdleProbe & {
  readonly daemon: NonNullable<VmIdleProbe["daemon"]>;
  readonly acpmux: NonNullable<VmIdleProbe["acpmux"]>;
};

/** The probe when every part of it answered, else what did not. */
function knownProbe(probe: VmIdleProbe | null): KnownVmIdleProbe | string {
  if (!probe) return "probe";
  const { daemon, acpmux } = probe;
  if (!daemon) return "daemon";
  if (!acpmux) return "acpmux";
  return { ...probe, daemon, acpmux };
}

/** The previous observation when it is this machine's and recent enough to vouch for the time since. */
function carriedObservation(previous: VmIdleObservation | null, providerVmId: string, now: number): VmIdleObservation | null {
  if (previous === null || previous.providerVmId !== providerVmId || previous.observedAt > now) return null;
  return now - previous.observedAt <= VM_IDLE_OBSERVATION_MAX_GAP_MS ? previous : null;
}

/**
 * Cores used on average since the previous idle probe; `reset` when the
 * counter went back; null when either side has no sample. An active probe
 * clears the observation, so the first idle probe after activity has no
 * baseline: the stretch starts there and the next probe measures it.
 */
function cpuCoresSince(previous: VmIdleObservation | null, probe: VmIdleProbe, now: number): number | "reset" | null {
  const before = previous?.cpuBusyMs;
  const after = probe.cpuBusyMs;
  if (!previous || !isCpuMs(before) || !isCpuMs(after)) return null;
  if (after < before) return "reset";
  const elapsed = now - previous.observedAt;
  return elapsed > 0 ? (after - before) / elapsed : null;
}

function activeReasons(probe: KnownVmIdleProbe, cpuCores: number | "reset" | null): string[] {
  return [
    probe.daemon.liveAgents > 0 && "live_agents",
    probe.acpmux.busySessions > 0 && "agent_turns",
    probe.busyTerminals > 0 && "busy_terminals",
    probe.sshSessions > 0 && "ssh_sessions",
    probe.inboundConnections > 0 && "inbound_connections",
    typeof cpuCores === "number" && cpuCores >= VM_IDLE_CPU_BUSY_CORES && "cpu",
  ].filter((why): why is string => typeof why === "string");
}

/**
 * The guest half of the probe, run by python3 as root. It reads only:
 * - the session daemon's `subscribe-activity` snapshot (cmux-tui
 *   server/activity.rs), over the socket named in /etc/cmux/daemon-socket,
 *   else (images baked before that file) the `cloud` session's own socket
 *   under the daemon user's runtime roots ($CMUX_IDLE_DAEMON_UID);
 * - the acpmux session list the shell part wrote to $CMUX_IDLE_ACPMUX
 *   (`NONE` when acpmux is not running, `ERR` when it could not be read);
 * - /proc: each pseudo-terminal's foreground process group (a group with
 *   anything but a shell in it, or a shell given -c or a script, is a running
 *   command; a process that exited mid-read is skipped, any other unreadable
 *   process makes the count unknown), sshd session processes,
 *   and established TCP connections into a listening port, counted when they
 *   reach the machine's private address ($CMUX_IDLE_PRIVATE_ADDRESSES) or sshd,
 *   except the daemon's own port ($CMUX_IDLE_DAEMON_PORT: the app's link, whose
 *   input the daemon already reports; the link alone is not activity), plus
 *   each stream the daemon (a `cmux-tui` process, by its socket inodes) holds to
 *   a listening loopback port: a port the app forwards over that link,
 *   and the aggregate `cpu` line of /proc/stat (busy CPU time since boot).
 * $CMUX_IDLE_PROC_ROOT, $CMUX_IDLE_DAEMON_SOCKET_FILE and
 * $CMUX_IDLE_DAEMON_SOCKET_ROOTS exist for tests.
 * Times and counts only leave the machine.
 */
export const VM_IDLE_PROBE_SCRIPT = String.raw`
import ipaddress, json, os, socket
proc = os.environ.get("CMUX_IDLE_PROC_ROOT", "/proc")
SHELLS = {"bash", "zsh", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "xonsh", "elvish"}

def daemon_sockets():
    out = []
    try:
        with open(os.environ.get("CMUX_IDLE_DAEMON_SOCKET_FILE", "/etc/cmux/daemon-socket")) as f:
            out.append(f.read().strip())
    except Exception:
        pass
    # The supervisor starts "cmux-tui server start --session cloud"; cmux-tui puts the
    # session socket in cmux-tui-<uid> under the runtime dir, else /tmp.
    uid = os.environ.get("CMUX_IDLE_DAEMON_UID", "")
    if uid.isdigit():
        roots = os.environ.get("CMUX_IDLE_DAEMON_SOCKET_ROOTS", "/run/user/" + uid + ":/tmp")
        out += [os.path.join(r, "cmux-tui-" + uid, "cloud.sock") for r in roots.split(":") if r]
    return [p for p in out if p]

def daemon():
    for path in daemon_sockets():
        a = daemon_at(path)
        if a is not None:
            return a
    return None

def daemon_at(path):
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(3)
        s.connect(path)
        s.sendall(b'{"id":1,"cmd":"subscribe-activity"}\n')
        buf = b""
        while b"\n" not in buf and len(buf) < 65536:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        s.close()
        msg = json.loads(buf.split(b"\n", 1)[0])
        a = msg.get("data", {}).get("activity") if msg.get("ok") is True else None
        if not isinstance(a, dict):
            return None
        return {k: a.get(k) for k in ("attached_clients", "live_agents", "last_user_input_at_ms", "last_agent_action_at_ms")}
    except Exception:
        return None

def acpmux():
    try:
        with open(os.environ["CMUX_IDLE_ACPMUX"]) as f:
            text = f.read()
    except Exception:
        return None
    if text.strip() == "NONE":
        return {"busy_sessions": 0, "last_updated_at_ms": None}
    try:
        sessions = json.loads(text).get("sessions")
    except Exception:
        return None
    if not isinstance(sessions, list):
        return None
    busy, latest = 0, None
    for s in sessions:
        if not isinstance(s, dict) or "peer" in s:
            continue
        pending = s.get("pendingPermissions")
        queued = s.get("queued", 0)
        # A durable queued prompt may be waiting while its session reports
        # "ready" and has no current turn. A malformed count is unknown.
        if type(queued) is not int or queued < 0:
            return None
        if (s.get("turn") is not None or (isinstance(pending, int) and pending > 0)
                or queued > 0 or s.get("queuePaused") is True
                or s.get("waitsForSlot") is True or s.get("moving") is True
                or s.get("waitingOn") is not None
                or s.get("status") in ("running", "waiting")):
            busy += 1
        u = s.get("updatedAt")
        if isinstance(u, int) and u > 0 and (latest is None or u > latest):
            latest = u
    return {"busy_sessions": busy, "last_updated_at_ms": latest}

# A process that exited between the listing and the read. Anything else that
# cannot be read could hide work, so it makes the answer unknown (None).
VANISHED = (FileNotFoundError, ProcessLookupError)

def processes():
    out = {}
    try:
        names = os.listdir(proc)
    except Exception:
        return None
    for name in names:
        if not name.isdigit():
            continue
        try:
            with open(os.path.join(proc, name, "stat"), "rb") as f:
                data = f.read().decode("utf-8", "replace")
        except VANISHED:
            continue
        except Exception:
            return None
        try:
            comm = data[data.index("(") + 1:data.rindex(")")]
            fields = data[data.rindex(")") + 2:].split()
            out[int(name)] = (comm, int(fields[2]), int(fields[4]), int(fields[5]))
        except Exception:
            return None
    return out

def cmdline(pid):
    """The process's arguments; None when it exited. Other read failures raise."""
    try:
        with open(os.path.join(proc, str(pid), "cmdline"), "rb") as f:
            raw = f.read()
    except VANISHED:
        return None
    # Keep empty arguments (--rcfile '' takes one); only the final NUL ends the list.
    parts = raw.split(b"\0")
    if parts and parts[-1] == b"":
        parts.pop()
    return [a.decode("utf-8", "replace") for a in parts]

SHELL_LONG_OPTION_OPERANDS = {"--rcfile", "--init-file"}

def shell_runs_command(pid):
    # A shell that is itself the command: -c anywhere in its options (alone or
    # in a cluster like -lc), or a script (the first operand after its options).
    # An option's own operand is not one: --rcfile FILE, and one argument per
    # o or O in a cluster (-o emacs, -io emacs, +O extglob). "--" and a bare "-"
    # end the options. A login or interactive shell (-bash, bash, zsh -l,
    # bash -i), or one reading commands from stdin (-s), is a prompt.
    args = cmdline(pid) or []
    rest = args[1:]
    i, runs_c, reads_stdin = 0, False, False
    while i < len(rest):
        arg = rest[i]
        if arg in SHELL_LONG_OPTION_OPERANDS:
            i += 2
        elif arg in ("--", "-"):
            i += 1
            break
        elif arg.startswith("--"):
            i += 1
        elif len(arg) > 1 and arg[0] in "-+":
            flags = arg[1:]
            runs_c = runs_c or "c" in flags
            reads_stdin = reads_stdin or "s" in flags
            i += 1 + flags.count("o") + flags.count("O")
        else:
            break
    return runs_c or (i < len(rest) and not reads_stdin)

def busy_terminals(procs):
    if procs is None:
        return None
    groups, foreground = {}, {}
    for pid, (comm, pgrp, tty, tpgid) in procs.items():
        groups.setdefault(pgrp, []).append((pid, comm))
        major = (tty >> 8) & 0xfff
        if 136 <= major <= 143 and tpgid > 0:
            foreground[tty] = tpgid
    n = 0
    try:
        for pgrp in foreground.values():
            members = groups.get(pgrp, [])
            if any(c not in SHELLS for _, c in members) or any(shell_runs_command(pid) for pid, _ in members):
                n += 1
    except Exception:
        return None
    return n

def ssh_sessions(procs):
    if procs is None:
        return None
    n = 0
    try:
        for pid in procs:
            args = cmdline(pid)
            if args and args[0].startswith("sshd") and "@" in args[0]:
                n += 1
    except Exception:
        return None
    return n

def address(hexaddr):
    raw = bytes.fromhex(hexaddr)
    if len(raw) == 4:
        return ipaddress.ip_address(raw[::-1])
    return ipaddress.ip_address(b"".join(raw[i:i + 4][::-1] for i in range(0, 16, 4)))

def daemon_socket_inodes(procs):
    if procs is None:
        return None
    inodes = set()
    for pid, (comm, _, _, _) in procs.items():
        if comm != "cmux-tui":
            continue
        fd_dir = os.path.join(proc, str(pid), "fd")
        try:
            names = os.listdir(fd_dir)
        except VANISHED:
            continue
        except Exception:
            return None
        for fd in names:
            try:
                target = os.readlink(os.path.join(fd_dir, fd))
            except VANISHED:
                continue
            except Exception:
                return None
            if target.startswith("socket:[") and target.endswith("]"):
                inodes.add(target[8:-1])
    return inodes

def inbound_connections(procs):
    private = set()
    for a in os.environ.get("CMUX_IDLE_PRIVATE_ADDRESSES", "").split(","):
        try:
            private.add(ipaddress.ip_address(a.strip()))
        except ValueError:
            pass
    rows = []
    for table in ("tcp", "tcp6"):
        try:
            with open(os.path.join(proc, "net", table)) as f:
                lines = f.read().splitlines()[1:]
        except FileNotFoundError:
            # On a kernel without IPv6 tcp6 can be absent; tcp is always required.
            if table == "tcp6":
                continue
            return None
        except Exception:
            return None
        for line in lines:
            if not line.strip():
                continue
            p = line.split()
            try:
                lhex, lport = p[1].split(":")
                rport = int(p[2].split(":")[1], 16)
                rows.append((address(lhex), int(lport, 16), p[3], rport, p[9]))
            except Exception:
                # A malformed row might be an established stream to a forwarded port.
                return None
    listening = {port for _, port, state, _, _ in rows if state == "0A"}
    daemon_port = os.environ.get("CMUX_IDLE_DAEMON_PORT", "")
    daemon_inodes = daemon_socket_inodes(procs)
    if daemon_inodes is None:
        # A daemon whose open sockets cannot be listed could be carrying a forwarded port.
        return None
    n = 0
    for local, port, state, rport, inode in rows:
        if state != "01":
            continue
        # A stream the daemon opened to a local service for the app (loopback-forward-v1 over its link).
        if inode in daemon_inodes and local.is_loopback and rport in listening and str(rport) != daemon_port:
            n += 1
            continue
        if port not in listening or str(port) == daemon_port:
            continue
        mapped = local.ipv4_mapped if local.version == 6 else None
        if port == 22 or local in private or (mapped is not None and mapped in private):
            n += 1
    return n

def cpu_busy_ms():
    try:
        with open(os.path.join(proc, "stat")) as f:
            fields = next((l.split() for l in f if l.startswith("cpu ")), None)
        ticks = [int(x) for x in fields[1:8]]
        if len(ticks) < 7:
            return None
        # user, nice, system, irq, softirq; not idle, iowait or steal.
        busy = ticks[0] + ticks[1] + ticks[2] + ticks[5] + ticks[6]
        try:
            hz = os.sysconf("SC_CLK_TCK")
        except (ValueError, OSError):
            hz = 100
        return busy * 1000 // (hz if hz > 0 else 100)
    except Exception:
        return None

procs = processes()
print(json.dumps({
    "v": 1,
    "daemon": daemon(),
    "acpmux": acpmux(),
    "busy_terminals": busy_terminals(procs),
    "ssh_sessions": ssh_sessions(procs),
    "inbound_connections": inbound_connections(procs),
    "cpu_busy_ms": cpu_busy_ms(),
}))
`;

/**
 * The whole probe as one root shell command: pick the daemon user's layout,
 * read acpmux's session list as that user (only when its daemon already runs,
 * so the probe never starts one), then run {@link VM_IDLE_PROBE_SCRIPT}.
 * `privateAddresses` are the machine's VPC addresses (providerMetadata);
 * only literal IP addresses pass.
 */
export function vmIdleProbeCommand(privateAddresses: readonly string[]): string {
  const addresses = privateAddresses.filter((a) => isIP(a) !== 0).join(",");
  const acp = (args: string) => cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" acp --json ${args}`);
  return [
    cmuxTuiLayoutSelector(),
    `t=$(mktemp) || exit 1`,
    `s=$(${acp("daemon status")} </dev/null 2>/dev/null)`,
    `case "$s" in *'"pid":'[0-9]*|*'"pid": '[0-9]*) ${acp("ls")} </dev/null >"$t" 2>/dev/null || printf ERR >"$t" ;; *'"running":false'*|*'"running": false'*) printf NONE >"$t" ;; *) printf ERR >"$t" ;; esac`,
    `CMUX_IDLE_ACPMUX="$t" CMUX_IDLE_DAEMON_UID="$(id -u "$CMUX_TUI_USER")" CMUX_IDLE_DAEMON_PORT=${CMUX_TUI_PORT} CMUX_IDLE_PRIVATE_ADDRESSES='${addresses}' python3 -I - <<'CMUX_IDLE_PY'\n${VM_IDLE_PROBE_SCRIPT}\nCMUX_IDLE_PY`,
    `rc=$?; rm -f "$t"; exit $rc`,
  ].join("\n");
}

function count(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : null;
}

function isCpuMs(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function isTime(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}

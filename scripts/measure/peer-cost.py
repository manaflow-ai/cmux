#!/usr/bin/env python3
"""What one acpmux `ssh://` peer costs, and what a daemon with many of them spends in its first minute (Linux).

Why: after a reboot a daemon with ~130 fleet peers opened ~130 `ssh -W` tunnels (plus a token-read ssh beside each
first dial) within seconds and the host's load hit 214. The goal is a peer that costs almost nothing, so no cap
is needed (Leo: "why not optimize it on our protools instead?"). This is the before/after harness.

It builds a fake fleet on one machine: a real OpenSSH `sshd` (unprivileged, loopback, its own host key), a far acpmux
daemon, and N ssh aliases (peer001..) that all reach that sshd. The near daemon gets N `ssh://peerNNN:PORT` peers and
runs the real dial path: real `ssh` binaries (through a logging wrapper first on PATH, which `exec`s the real ssh
with the fake fleet's ssh config), real key exchange and login, real token read, real WebSocket handshake. Nothing
is faked but the hosts being one machine. `--style` picks the ssh config the aliases have:
  plain   a bare Host block (HostName, key, no multiplexing)
  fleet   the shape of Leo's fleet config: a ProxyCommand relay (a Python start per ssh) handing ssh a socket
          (ProxyUseFdpass), ControlMaster auto + ControlPersist 90 (a shared master per host), 10 s keepalive.

  cold-start   start the near daemon with N peers; for SECS seconds report: ssh processes spawned (exact, from the
               wrapper's log; split into `-W` tunnels and token reads), peak concurrent ssh (masters included) and
               peak processes of the run, total CPU seconds (daemon + everything it ran, reaped or live, from /proc),
               daemon RSS, RSS per `-W` client and per master, the far side's CPU (sshd + far daemon) separately,
               the CPU rate of the last third (what idle peers cost), load average, time until all links are up.
  handshake    one login at a time to a fresh alias, REPS times: CPU (rusage) and wall of `ssh -W` (the tunnel) and of
               the token read, a master's CPU, the far sshd's CPU per login, the phases of `ssh -vvv`, RSS of an
               idle tunnel. `--real-host H` repeats the CPU part against a host of the machine's own ssh config.
  both         baseline (0 peers), cold-start in each style, handshake in each style: one JSON object.

Run (a fleet Linux machine; never a Mac of Leo's; the release build needs the Rust setup):
  cmux-ci test --setup rust --artifact DIR -- 'scripts/measure/peer-cost-linux.sh [peers=130] [secs=60] [reps=20]'
or on a machine with a built binary: python3 scripts/measure/peer-cost.py both --acpmux PATH [--peers 130]
Prints PEERCOST lines, then {"rows": [...]} (the perf rows) as one JSON line.
"""
import argparse
import json
import os
import re
import selectors
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time

TICK = os.sysconf("SC_CLK_TCK")
SSHD = next((p for p in ("/usr/sbin/sshd", "/usr/local/sbin/sshd", shutil.which("sshd") or "") if p and os.path.exists(p)), None)
SSH = shutil.which("ssh") or "/usr/bin/ssh"
SSH_PEER_PORT_DEFAULT = 47811
NOSTAT = (0, 0, 0, "")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def stat_of(pid):
    """(ppid, cpu_self_s, cpu_reaped_children_s, comm) from /proc/PID/stat, or None."""
    try:
        raw = open(f"/proc/{pid}/stat").read()
    except OSError:
        return None
    rp = raw.rindex(")")
    comm = raw[raw.index("(") + 1:rp]
    f = raw[rp + 2:].split()
    ppid, ut, st, cut, cst = int(f[1]), int(f[11]), int(f[12]), int(f[13]), int(f[14])
    return ppid, (ut + st) / TICK, (cut + cst) / TICK, comm


def rss_kb(pid, key="VmRSS"):
    try:
        for line in open(f"/proc/{pid}/status"):
            if line.startswith(key + ":"):
                return int(line.split()[1])
    except OSError:
        pass
    return None


def children_map():
    kids = {}
    for name in os.listdir("/proc"):
        if name.isdigit():
            s = stat_of(int(name))
            if s:
                kids.setdefault(s[0], []).append(int(name))
    return kids


def descendants(root, kids):
    out, todo = [], list(kids.get(root, []))
    while todo:
        p = todo.pop()
        out.append(p)
        todo.extend(kids.get(p, []))
    return out


def cmdline(pid):
    try:
        return open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
    except OSError:
        return ""


def cpu_of(pids):
    """CPU seconds of each pid (own plus the children it reaped), summed. A live process counts once, as itself."""
    total = 0.0
    for p in pids:
        s = stat_of(p) or NOSTAT
        total += s[1] + s[2]
    return total


def own_cpu(pid, include_reaped_children=False):
    stat = stat_of(pid)
    if not stat:
        return None
    return stat[1] + (stat[2] if include_reaped_children else 0.0)


class Fleet:
    """The fake fleet: sshd, the far daemon, the ssh config and the logging wrapper."""

    def __init__(self, acpmux, tmp, peers, style="plain"):
        if not SSHD:
            raise RuntimeError("peer-cost: no sshd on this machine (apt-get install openssh-server; it is not started)")
        self.acpmux, self.tmp, self.n, self.style = acpmux, tmp, peers, style
        self.user = os.environ.get("USER") or subprocess.check_output(["id", "-un"], text=True).strip()
        self.sshd_port, self.ws_port = free_port(), free_port()
        self.token = os.urandom(32).hex()
        self.build()

    def p(self, *a):
        return os.path.join(self.tmp, *a)

    def build(self):
        os.makedirs(self.p("far", ".acpmux", "run"), exist_ok=True)
        os.makedirs(self.p("near", ".acpmux"), exist_ok=True)
        os.makedirs(self.p("bin"), exist_ok=True)
        for k in ("host_key", "client_key"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", self.p(k)], check=True)
        shutil.copy(self.p("client_key.pub"), self.p("authorized_keys"))
        # A remote command (the token read) runs with the far daemon's HOME, so `~/.acpmux/config.json` is its.
        open(self.p("force.sh"), "w").write(f'#!/bin/sh\nHOME={self.p("far")} exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"\n')
        os.chmod(self.p("force.sh"), 0o755)
        open(self.p("sshd_config"), "w").write(
            f"Port {self.sshd_port}\nListenAddress 127.0.0.1\nHostKey {self.p('host_key')}\n"
            f"PidFile {self.p('sshd.pid')}\nAuthorizedKeysFile {self.p('authorized_keys')}\n"
            "PasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\n"
            f"AllowTcpForwarding yes\nForceCommand {self.p('force.sh')}\nLogLevel ERROR\nMaxStartups 10000:30:20000\n"
            "MaxSessions 100\n")
        open(self.p("ssh_config"), "w").write(
            f"Host peer*\n  HostName 127.0.0.1\n  Port {self.sshd_port}\n  User {self.user}\n"
            f"  IdentityFile {self.p('client_key')}\n  IdentitiesOnly yes\n  UserKnownHostsFile {self.p('known_hosts')}\n"
            "  StrictHostKeyChecking no\n  LogLevel ERROR\n" + self.fleet_lines())
        # Logs one line per spawn (time, pid, argv) and becomes the real ssh: same pid, same CPU accounting.
        open(self.p("bin", "ssh"), "w").write(
            f'#!/bin/bash\nprintf \'%s %s %s\\n\' "$EPOCHREALTIME" "$$" "$*" >> {self.p("ssh.log")}\n'
            f'exec {SSH} -F {self.p("ssh_config")} "$@"\n')
        os.chmod(self.p("bin", "ssh"), 0o755)
        open(self.p("far", ".acpmux", "config.json"), "w").write(
            json.dumps({"websocket": {"listen": f"127.0.0.1:{self.ws_port}", "token": self.token}}))
        peers = {f"peer{i:03d}": {"url": f"ssh://peer{i:03d}:{self.ws_port}"} for i in range(1, self.n + 1)}
        open(self.p("near", ".acpmux", "config.json"), "w").write(json.dumps({"peers": peers}))

    def fleet_lines(self):
        """The shape of Leo's fleet ssh config: a ProxyCommand relay that hands ssh a connected socket
        (ProxyUseFdpass; the real one is a Python script that tries each route), a shared master per host
        (ControlMaster auto, ControlPersist 90; %n in its path: every alias reaches one sshd, a %C hash would share one master) and the 10 s keepalive. This relay has one route: the same Python start."""
        if self.style != "fleet":
            return ""
        relay = self.p("relay.py")
        open(relay, "w").write(
            "import array, os, socket, sys\n"
            "s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), 10)\n"
            "c = socket.socket(fileno=os.dup(1))\n"
            "c.sendmsg([b'\\0'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [s.fileno()]))])\n")
        return (f"  ProxyCommand python3 {relay} {self.sshd_port}\n  ProxyUseFdpass yes\n  ControlMaster auto\n"
                f"  ControlPath {self.p('cm-%n')}\n  ControlPersist 90\n  ServerAliveInterval 10\n  ServerAliveCountMax 3\n")

    def far_pids(self, kids):
        return {self.sshd.pid, self.far.pid} | set(descendants(self.sshd.pid, kids)) | set(descendants(self.far.pid, kids))

    def ours(self, kids):
        """Pids this run started on the near side: the near daemon's descendants plus, in the fleet style, the
        ControlPersist masters (a client's child that outlived it) and relays, found by this run's scratch
        directory in their command line."""
        near = getattr(self, "near", None)
        desc = set(descendants(near.pid, kids)) if near else set()
        found = set(desc)
        if self.style == "fleet":
            far = self.far_pids(kids)
            for name in os.listdir("/proc"):
                pid = int(name) if name.isdigit() else 0
                if pid and pid not in desc and pid not in far and pid != os.getpid():
                    st = stat_of(pid)
                    if st and st[3] in ("ssh", "python3") and self.tmp in cmdline(pid):
                        found.add(pid)
        return found

    def env(self, home, path):
        return {"PATH": path, "HOME": home, "USER": self.user, "ACPMUX_HOME": os.path.join(home, ".acpmux"),
                "ACPMUX_SOCKET": os.path.join(home, "s.sock"), "ACPMUX_LOGIN_ENV": "0", "ACPMUX_AGENT_LAUNCH": "deny",
                "TMPDIR": self.tmp}

    def start_far(self):
        sysdirs = "/usr/local/bin:/usr/bin:/bin"
        self.sshd = subprocess.Popen([SSHD, "-D", "-e", "-f", self.p("sshd_config")], stdin=subprocess.DEVNULL,
                                     stderr=open(self.p("sshd.err"), "w"))
        self.far = subprocess.Popen(
            [self.acpmux, "daemon", "run", "--memory", "--log", "warn"], env=self.env(self.p("far"), sysdirs),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=open(self.p("far.err"), "w"))
        until = time.time() + 30
        while time.time() < until:
            for port in (self.sshd_port, self.ws_port):
                try:
                    socket.create_connection(("127.0.0.1", port), 0.2).close()
                except OSError:
                    break
            else:
                return
            time.sleep(0.1)
        raise RuntimeError("peer-cost: the fake fleet (sshd, far daemon) did not come up:\n" + open(self.p("sshd.err")).read()
                           + open(self.p("far.err")).read())

    def start_near(self):
        open(self.p("ssh.log"), "w").close()
        self.near = subprocess.Popen(
            [self.acpmux, "daemon", "run", "--memory", "--log", "warn"],
            env=self.env(self.p("near"), f'{self.p("bin")}:/usr/local/bin:/usr/bin:/bin'),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=open(self.p("near.err"), "w"))
        return self.near

    def rpc(self, home, method):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(5)
        s.connect(os.path.join(home, "s.sock"))
        s.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": {}}) + "\n").encode())
        buf = b""
        while True:
            chunk = s.recv(1 << 20)
            if not chunk:
                return None
            buf += chunk
            for line in buf.split(b"\n")[:-1]:
                try:
                    v = json.loads(line)
                except ValueError:
                    continue
                if v.get("id") == 1:
                    s.close()
                    return v
            buf = buf.split(b"\n")[-1]

    def stop(self):
        """End what this run started: the near daemon (its ssh children die with it), then any ControlPersist master
        and relay it left (named by this run's scratch directory), the far daemon and sshd."""
        try:
            leftovers = self.ours(children_map())
        except Exception:  # noqa: BLE001
            leftovers = set()
        for pr in (getattr(self, "near", None), getattr(self, "far", None), getattr(self, "sshd", None)):
            if pr and pr.poll() is None:
                pr.terminate()
                try:
                    pr.wait(5)
                except subprocess.TimeoutExpired:
                    pr.kill()
        for pid in leftovers:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass


def peers_up(fleet):
    """How many peers the near daemon reports connected, and one raw row (to read the shape of)."""
    try:
        v = fleet.rpc(fleet.p("near"), "_acpmux/peers")
    except (OSError, ValueError):
        return None, None
    rows = ((v or {}).get("result") or {}).get("peers") or []
    if isinstance(rows, dict):
        rows = list(rows.values())
    up = sum(1 for r in rows if isinstance(r, dict) and (r.get("connected") is True or r.get("state") == "connected"))
    return up, (rows[0] if rows else None)


def cold_start(acpmux, peers, secs, style, keep, scratch_root=None):
    tmp = tempfile.mkdtemp(prefix="cold-", dir=scratch_root)
    fleet = Fleet(acpmux, tmp, peers, style)
    try:
        fleet.start_far()
        far0 = cpu_of(fleet.far_pids(children_map()))
        near = fleet.start_near()
        t0 = time.time()
        peak_ssh = peak_tunnels = peak_procs = masters_peak = peak_daemon_rss = 0
        seen_procs, cpu_seen, tunnel_rss, master_rss = set(), {}, {}, {}
        series, all_up_at, sample_row = [], None, None
        last_rpc, mark = 0, None  # `mark`: CPU at two thirds of the window; the rest of it is the idle, steady cost
        while time.time() - t0 < secs:
            now = time.time() - t0
            kids = children_map()
            mine = fleet.ours(kids)
            seen_procs |= mine
            for pid in {near.pid} | mine:
                cpu = own_cpu(pid, include_reaped_children=pid == near.pid)
                if cpu is not None:
                    cpu_seen[pid] = max(cpu_seen.get(pid, 0.0), cpu)
            ssh = [d for d in mine if (stat_of(d) or NOSTAT)[3] == "ssh"]
            tun = masters = 0
            for d in ssh:
                cl = cmdline(d)
                if " -W " in cl:
                    tun += 1
                    tunnel_rss[d] = max(tunnel_rss.get(d, 0), rss_kb(d) or 0)
                elif cl.startswith("ssh: "):
                    masters += 1
                    master_rss[d] = max(master_rss.get(d, 0), rss_kb(d) or 0)
            peak_ssh, peak_tunnels, masters_peak = max(peak_ssh, len(ssh)), max(peak_tunnels, tun), max(masters_peak, masters)
            peak_procs = max(peak_procs, len(mine))
            peak_daemon_rss = max(peak_daemon_rss, rss_kb(near.pid) or 0)
            if mark is None and now >= secs * 2 / 3:
                mark = (now, sum(cpu_seen.values()))
            # RPC row serialization is itself work.  Only sample connection state until all links are
            # up (and at the end); the last third is a genuinely quiescent idle-cost window.
            if now - last_rpc >= 1 and (all_up_at is None or now < secs * 2 / 3):
                last_rpc = now
                n_up, row = peers_up(fleet)
                sample_row = sample_row or row
                series.append((round(now, 1), len(ssh), n_up))
                if peers and n_up is not None and n_up >= peers and all_up_at is None:
                    all_up_at = round(now, 1)
            time.sleep(0.1)
        end = time.time() - t0
        final_mine = fleet.ours(children_map())
        for pid in {near.pid} | final_mine:
            cpu = own_cpu(pid, include_reaped_children=pid == near.pid)
            if cpu is not None:
                cpu_seen[pid] = max(cpu_seen.get(pid, 0.0), cpu)
        if near.poll() is not None:
            raise RuntimeError(f"cold-start near daemon exited with status {near.returncode}")
        total = sum(cpu_seen.values())
        own = stat_of(near.pid)
        far_cpu = cpu_of(fleet.far_pids(children_map())) - far0
        n_up, _ = peers_up(fleet)
        if n_up is None:
            raise RuntimeError("cold-start near daemon did not answer its final peer-status RPC")
        log = [l.split(" ", 2) for l in open(fleet.p("ssh.log")).read().splitlines()]
        tunnels = sum(1 for l in log if len(l) > 2 and " -W " in " " + l[2] + " ")
        rss, mrss = sorted(tunnel_rss.values()), sorted(master_rss.values())
        mb = lambda kb: round(kb / 1024, 2)  # noqa: E731
        out = {
            "peers": peers, "style": style, "secs": secs,
            "ssh_spawned": len(log), "ssh_tunnels": tunnels, "ssh_token_reads": len(log) - tunnels,
            "peak_concurrent_ssh": peak_ssh, "peak_concurrent_tunnel_clients": peak_tunnels, "peak_masters": masters_peak,
            "peak_processes_of_the_run": peak_procs, "processes_seen_in_all": len(seen_procs),
            "total_cpu_s_near": round(total, 2), "daemon_own_cpu_s": round(own[1], 2) if own else None,
            "steady_cpu_percent_of_one_core_last_third": round((total - mark[1]) / max(1e-9, end - mark[0]) * 100, 2) if mark else None,
            "far_cpu_s_sshd_and_far_daemon": round(far_cpu, 2),
            "daemon_rss_mb_final": mb(rss_kb(near.pid) or 0), "daemon_rss_mb_peak": mb(max(rss_kb(near.pid, "VmHWM") or 0, peak_daemon_rss)),
            "ssh_tunnel_rss_mb_median": mb(statistics.median(rss)) if rss else None,
            "ssh_master_rss_mb_median": mb(statistics.median(mrss)) if mrss else None,
            "loadavg1_at_end": float(open("/proc/loadavg").read().split()[0]),
            "peers_up_at_end": n_up, "all_peers_up_s": all_up_at,
            "series_s_ssh_up": series[:: max(1, len(series) // 20)], "peer_row_shape": sample_row,
        }
        if keep:
            out["tmp"] = tmp
        return out
    finally:
        fleet.stop()
        if not keep:
            shutil.rmtree(tmp, ignore_errors=True)


def timed_ssh(argv, hold=False, payload=b"", timeout=30):
    """One checked ssh run: (wall_s to first byte/end, cpu_s, idle rss, user cpu).

    The child is drained through a selector so a verbose or large response cannot deadlock the
    probe.  A nonzero exit, missing first byte, or deadline is a failed sample.
    """
    t = time.monotonic()
    pr = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    rss = None
    waited = None

    def reap_until(deadline):
        while True:
            try:
                waited_pid, status, ru = os.wait4(pr.pid, os.WNOHANG)
            except ChildProcessError:
                return None
            if waited_pid:
                return status, ru
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                try:
                    os.kill(pr.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    _, status, ru = os.wait4(pr.pid, 0)
                except ChildProcessError:
                    return None
                return status, ru
            time.sleep(min(0.05, remaining))

    try:
        if payload:
            pr.stdin.write(payload)
            pr.stdin.flush()
        pr.stdin.close()
        if hold:
            # Keep a successful tunnel alive long enough to sample its RSS, then end our own probe.
            deadline = time.monotonic() + 1.5
            while time.monotonic() < deadline:
                time.sleep(0.05)
            rss = rss_kb(pr.pid)
            try:
                os.kill(pr.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            waited = reap_until(time.monotonic() + 2)
        else:
            selector = selectors.DefaultSelector()
            selector.register(pr.stdout, selectors.EVENT_READ)
            first_at = None
            eof = False
            while not eof:
                remaining = t + timeout - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"ssh probe exceeded {timeout}s: {' '.join(argv)}")
                events = selector.select(min(remaining, 0.25))
                if not events:
                    continue
                for key, _ in events:
                    chunk = os.read(key.fileobj.fileno(), 1 << 16)
                    if chunk:
                        if first_at is None:
                            first_at = time.monotonic()
                    else:
                        eof = True
                        selector.unregister(key.fileobj)
                        break
            selector.close()
            if payload and first_at is None:
                raise RuntimeError(f"ssh probe returned no response: {' '.join(argv)}")
            wall = (first_at or time.monotonic()) - t if payload else time.monotonic() - t
            waited = reap_until(t + timeout)
    except BaseException:
        try:
            os.kill(pr.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.wait4(pr.pid, 0)
        except ChildProcessError:
            pass
        raise
    if waited is None:
        raise RuntimeError(f"ssh probe could not reap child: {' '.join(argv)}")
    status, ru = waited
    exit_code = os.waitstatus_to_exitcode(status)
    if not hold and exit_code != 0:
        raise RuntimeError(f"ssh probe exited {exit_code}: {' '.join(argv)}")
    return wall if not hold else time.monotonic() - t, ru.ru_utime + ru.ru_stime, rss, ru.ru_utime


def phases(argv):
    """`ssh -vvv` stamped line by line: when each phase of one login begins, ms since spawn."""
    t0 = time.monotonic()
    pr = subprocess.Popen(argv[:1] + ["-vvv"] + argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
    marks, kex = {}, None
    want = [("connect_start", rb"Connecting to"), ("tcp_connected", rb"Connection established"),
            ("banner", rb"Remote protocol version"), ("kexinit_sent", rb"SSH2_MSG_KEXINIT sent"),
            ("kex_reply", rb"SSH2_MSG_KEX_ECDH_REPLY|expecting SSH2_MSG_KEX"),
            ("newkeys", rb"SSH2_MSG_NEWKEYS received"), ("auth_start", rb"SSH2_MSG_SERVICE_ACCEPT received"),
            ("authenticated", rb"Authenticated to"), ("channel_open", rb"Local connections to|channel 0: new|direct-tcpip")]
    pr.stdin.write(b"x")
    pr.stdin.flush()
    end = time.monotonic() + 8
    selector = selectors.DefaultSelector()
    selector.register(pr.stderr, selectors.EVENT_READ)
    buf = b""
    try:
        while time.monotonic() < end and "channel_open" not in marks:
            for key, _ in selector.select(min(0.25, max(0, end - time.monotonic()))):
                chunk = os.read(key.fileobj.fileno(), 1 << 16)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buf += chunk
                *lines, buf = buf.splitlines(keepends=True)
                for line in lines:
                    now = time.monotonic() - t0
                    for name, pat in want:
                        if name not in marks and re.search(pat, line):
                            marks[name] = round(now * 1000, 1)
                    m = re.search(rb"kex: algorithm: (\S+)", line)
                    if m and not kex:
                        kex = m.group(1).decode()
    finally:
        selector.close()
        try:
            os.kill(pr.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.wait4(pr.pid, 0)
        except ChildProcessError:
            pass
    return {"ms_since_spawn": marks, "kex": kex}


def with_opts(argv, extra):
    """argv (wrapper, options..., rest) with extra ssh options right after the wrapper."""
    return argv[:1] + list(extra) + argv[1:]


def handshake_real_host(real_host, reps):
    """Measure a real configured host without starting the Linux-only fake fleet."""
    opts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=no",
            "-o", "ControlPath=none", "-o", "ControlPersist=no"]
    probe = b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    rows = [timed_ssh([SSH, *opts, "-W", f"127.0.0.1:{SSH_PEER_PORT_DEFAULT}", "--", real_host], payload=probe)
            for _ in range(max(3, reps // 4))]
    return {"real_host": {"client_cpu_ms_median": round(statistics.median(r[1] for r in rows) * 1000, 1),
                           "wall_ms_median": round(statistics.median(r[0] for r in rows) * 1000, 1),
                           "n": len(rows)}}


def handshake(acpmux, reps, style, real_host, keep, scratch_root=None):
    if real_host and style == "plain":
        return handshake_real_host(real_host, reps)
    tmp = tempfile.mkdtemp(prefix="handshake-", dir=scratch_root)
    fleet = Fleet(acpmux, tmp, 1, style)
    try:
        fleet.start_far()
        port, wrap = fleet.ws_port, fleet.p("bin", "ssh")
        opts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        tun = lambda alias: [wrap, *opts, "-W", f"127.0.0.1:{port}", "--", alias]  # noqa: E731
        read = lambda alias: [wrap, *opts, "--", alias,  # noqa: E731
                              "cat ~/.acpmux/config.json; printf '\\0'; cat ~/.acpmux/run/peer.token 2>/dev/null"]
        probe = b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        timed_ssh(tun("peerwarm"), payload=probe)  # warm: page cache, known_hosts
        out = {"style": style, "reps": reps}

        def sshd_cpu():
            return cpu_of({fleet.sshd.pid} | set(descendants(fleet.sshd.pid, children_map())))

        def batch(label, make, payload, first, extra=()):
            """A fresh alias per rep: each login is a first dial (its own key exchange, its own master)."""
            sshd0 = sshd_cpu()
            masters_before = {p for p in fleet.ours(children_map()) if (stat_of(p) or NOSTAT)[3] == "ssh"} if style == "fleet" else set()
            rows = [timed_ssh(with_opts(make(f"peer{first + i:03d}"), extra), payload=payload) for i in range(reps)]
            time.sleep(0.5)
            masters = [p for p in fleet.ours(children_map()) if (stat_of(p) or NOSTAT)[3] == "ssh"] if style == "fleet" else []
            cpu = [r[1] for r in rows]
            new_masters = set(masters) - masters_before
            out[label] = {"client_cpu_ms_median": round(statistics.median(cpu) * 1000, 1),
                          "client_cpu_ms_mean": round(statistics.mean(cpu) * 1000, 1),
                          "client_user_ms_median": round(statistics.median(r[3] for r in rows) * 1000, 1),
                          "master_cpu_ms_per_login": round(cpu_of(new_masters) / reps * 1000, 1),
                          "wall_ms_median": round(statistics.median(r[0] for r in rows) * 1000, 1),
                          "far_sshd_cpu_ms_per_login": round((sshd_cpu() - sshd0) / reps * 1000, 1)}

        batch("tunnel_login", tun, probe, 1)
        # What the key exchange costs: the same login with the classic curve25519 exchange instead of the default's
        # post-quantum hybrid, and the process alone (`ssh -V`: start, libraries, no network).
        batch("tunnel_login_curve25519", tun, probe, 300, ("-o", "KexAlgorithms=curve25519-sha256"))
        v = [timed_ssh([SSH, "-V"], payload=b"") for _ in range(reps)]
        out["ssh_V_process_alone"] = {"cpu_ms_median": round(statistics.median(x[1] for x in v) * 1000, 1)}
        batch("token_read_login", read, b"", 200)
        idle = timed_ssh(tun("peer500"), hold=True)
        out["idle_tunnel_client_rss_mb"] = round(idle[2] / 1024, 2) if idle[2] else None
        out["phases"] = phases(tun("peer600"))
        out["kex"] = out["phases"]["kex"]
        if style == "fleet":  # the next login to a host with a live master: a mux client only
            again = [timed_ssh(tun("peer001"), payload=probe) for _ in range(reps)]
            out["tunnel_login_via_live_master"] = {"client_cpu_ms_median": round(statistics.median(a[1] for a in again) * 1000, 1),
                                                    "wall_ms_median": round(statistics.median(a[0] for a in again) * 1000, 1)}
        return out
    finally:
        fleet.stop()
        if not keep:
            shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["cold-start", "handshake", "both"])
    ap.add_argument("--acpmux", required=True, help="a release acpmux binary")
    ap.add_argument("--peers", type=int, default=130)
    ap.add_argument("--secs", type=int, default=60)
    ap.add_argument("--reps", type=int, default=20)
    ap.add_argument("--style", choices=["plain", "fleet", "all"], default="all", help="the ssh config of the aliases")
    ap.add_argument("--real-host", help="handshake: also time ssh -W to this host of the machine's own ssh config")
    ap.add_argument("--keep", action="store_true", help="keep the scratch directories (logs, configs)")
    ap.add_argument("--scratch-root", help="private directory owned by the caller for all scratch data")
    ap.add_argument("--out", help="write the JSON here as well")
    a = ap.parse_args()
    styles = ["plain", "fleet"] if a.style == "all" else [a.style]
    result = {}
    scratch_root = a.scratch_root or tempfile.mkdtemp(prefix="peercost-run-")
    os.makedirs(scratch_root, mode=0o700, exist_ok=True)
    failures = []

    def stage(name, fn, *args):
        """One stage's result, or its failure as a result: one broken style does not lose the others' numbers."""
        try:
            result[name] = fn(*args)
        except Exception as e:  # noqa: BLE001
            result[name] = {"error": f"{type(e).__name__}: {e}"}
            failures.append(name)
        return result[name]

    if a.mode in ("cold-start", "both"):
        base = stage("cold_start_baseline_0_peers", cold_start, a.acpmux, 0, a.secs, "plain", a.keep, scratch_root)
        for st in styles:
            r = stage(f"cold_start_{st}", cold_start, a.acpmux, a.peers, a.secs, st, a.keep, scratch_root)
            if a.peers and "error" not in r and "error" not in base:
                r["per_peer"] = {
                    "total_cpu_ms": round((r["total_cpu_s_near"] - base["total_cpu_s_near"]) / a.peers * 1000, 1),
                    "daemon_own_cpu_ms": round((r["daemon_own_cpu_s"] - base["daemon_own_cpu_s"]) / a.peers * 1000, 1),
                    "daemon_rss_mb": round((r["daemon_rss_mb_final"] - base["daemon_rss_mb_final"]) / a.peers, 3),
                }
    if a.mode in ("handshake", "both"):
        for st in styles:
            stage(f"handshake_{st}", handshake, a.acpmux, a.reps, st, a.real_host, a.keep, scratch_root)
    rows = []
    for st in styles:
        cs = result.get(f"cold_start_{st}")
        if cs and "error" not in cs:
            for k in ("ssh_spawned", "peak_concurrent_ssh", "peak_processes_of_the_run", "total_cpu_s_near",
                      "daemon_rss_mb_peak", "ssh_tunnel_rss_mb_median"):
                rows.append({"name": f"acpmux.peer_cost.{st}.{k}", "value": cs[k], "peers": cs["peers"]})
        hs = result.get(f"handshake_{st}")
        if hs and "error" not in hs:
            if "tunnel_login" in hs:
                rows.append({"name": f"acpmux.peer_cost.{st}.login_cpu_ms", "value": hs["tunnel_login"]["client_cpu_ms_median"]})
            elif "real_host" in hs:
                rows.append({"name": f"acpmux.peer_cost.{st}.real_host_login_cpu_ms", "value": hs["real_host"]["client_cpu_ms_median"]})
    for k, v in result.items():
        print(f"PEERCOST {k} {json.dumps(v, sort_keys=True)}")
    result["rows"] = rows
    if a.out:
        json.dump(result, open(a.out, "w"), indent=1)
    print(json.dumps({"rows": rows}))
    if failures:
        print(f"peer-cost: failed stages: {', '.join(failures)}", file=sys.stderr)
    if not a.keep and not a.scratch_root:
        shutil.rmtree(scratch_root, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

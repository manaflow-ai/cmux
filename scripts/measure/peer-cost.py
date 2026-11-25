#!/usr/bin/env python3
"""What one acpmux `ssh://` peer costs, and what a daemon with many of them spends in its first minute (Linux).

Why: after a reboot a daemon with ~130 fleet peers opened ~130 `ssh -W` tunnels (plus a token-read ssh beside each
first dial) within seconds and the host's load hit 214. The goal is a peer that costs almost nothing, so no cap
is needed (Leo: "why not optimize it on our protools instead?"). This is the before/after harness.

It builds a fake fleet on one machine: a real OpenSSH `sshd` (unprivileged, loopback, its own host key), a far acpmux
daemon, and 130 ssh aliases (peer001..) that all reach that sshd. The near daemon gets 130 `ssh://peerNNN:PORT`
peers and runs the real dial path: real `ssh` binaries (through a logging wrapper first on PATH, which then
`exec`s the real ssh with the fake fleet's ssh config), real key exchange and login, real token read, real
WebSocket handshake. Nothing is faked but the 130 hosts being one machine.

  cold-start   start the near daemon with N peers; for SECS seconds report: ssh processes spawned (exact, from the
               wrapper's log; split into `-W` tunnels and token reads), peak concurrent ssh, total CPU seconds
               (daemon + every ssh it ran, reaped or live, from /proc), daemon RSS (peak, final), RSS per ssh -W
               tunnel, the far side's CPU (sshd + far daemon) separately, load average, time to all links up.
  handshake    one login at a time, REPS times: CPU (user+sys, rusage) and wall of `ssh -W` (the tunnel) and of the
               token read, the far sshd's CPU per login, the phases of `ssh -vvv` (connect, key exchange, auth,
               channel), RSS of one idle tunnel. `--real-host H` repeats the CPU part against a real host from
               the machine's own ssh config (a tailnet peer).
  both         the two, one JSON object.

Run (a fleet Linux machine; never a Mac of Leo's; the release build needs the Rust setup):
  cmux-ci test --setup rust -- 'scripts/measure/peer-cost-linux.sh [peers=130] [secs=60] [reps=20]'
or on a machine with a built binary: python3 scripts/measure/peer-cost.py both --acpmux PATH [--peers 130]
Prints PEERCOST lines, then {"rows": [...]} (the perf rows) as one JSON line.
"""
import argparse
import json
import os
import re
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


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def stat_of(pid):
    """(ppid, cpu_self_s, cpu_children_s, comm) from /proc/PID/stat, or None."""
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


def tree_cpu(pid):
    """CPU seconds of `pid`, the children it reaped, and every live descendant not yet reaped by it."""
    s = stat_of(pid)
    if not s:
        return 0.0
    kids = children_map()
    live = sum((stat_of(d) or (0, 0, 0, ""))[1] for d in descendants(pid, kids))
    return s[1] + s[2] + live


class Fleet:
    """The fake fleet: sshd, the far daemon, the ssh config and the logging wrapper."""

    def __init__(self, acpmux, tmp, peers):
        if not SSHD:
            sys.exit("peer-cost: no sshd on this machine (apt-get install openssh-server; it is not started)")
        self.acpmux, self.tmp, self.n = acpmux, tmp, peers
        self.user = os.environ.get("USER") or subprocess.check_output(["id", "-un"], text=True).strip()
        self.sshd_port, self.ws_port = free_port(), free_port()
        self.token = os.urandom(32).hex()
        self.procs = []
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
            "  StrictHostKeyChecking no\n  LogLevel ERROR\n")
        # Logs one line per spawn (time, pid, argv) and becomes the real ssh: same pid, same CPU accounting.
        open(self.p("bin", "ssh"), "w").write(
            f'#!/bin/bash\nprintf \'%s %s %s\\n\' "$EPOCHREALTIME" "$$" "$*" >> {self.p("ssh.log")}\n'
            f'exec {SSH} -F {self.p("ssh_config")} "$@"\n')
        os.chmod(self.p("bin", "ssh"), 0o755)
        open(self.p("far", ".acpmux", "config.json"), "w").write(
            json.dumps({"websocket": {"listen": f"127.0.0.1:{self.ws_port}", "token": self.token}}))
        peers = {f"peer{i:03d}": {"url": f"ssh://peer{i:03d}:{self.ws_port}"} for i in range(1, self.n + 1)}
        open(self.p("near", ".acpmux", "config.json"), "w").write(json.dumps({"peers": peers}))

    def env(self, home, path):
        e = {"PATH": path, "HOME": home, "USER": self.user, "ACPMUX_HOME": os.path.join(home, ".acpmux"),
             "ACPMUX_SOCKET": os.path.join(home, "s.sock"), "ACPMUX_LOGIN_ENV": "0", "ACPMUX_AGENT_LAUNCH": "deny",
             "TMPDIR": self.tmp}
        return e

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
        sys.exit("peer-cost: the fake fleet (sshd, far daemon) did not come up:\n" + open(self.p("sshd.err")).read()
                 + open(self.p("far.err")).read())

    def start_near(self):
        open(self.p("ssh.log"), "w").close()
        self.near_started = time.time()
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
        for pr in (getattr(self, "near", None), getattr(self, "far", None), getattr(self, "sshd", None)):
            if pr and pr.poll() is None:
                pr.terminate()
                try:
                    pr.wait(5)
                except subprocess.TimeoutExpired:
                    pr.kill()
        # Only what this run started: the ssh children of its own near daemon die with it (kill_on_drop).


def peers_up(fleet):
    """How many peers the near daemon reports connected, and one raw row (to read the shape of)."""
    try:
        v = fleet.rpc(fleet.p("near"), "_acpmux/peers")
    except (OSError, ValueError):
        return None, None
    rows = ((v or {}).get("result") or {}).get("peers") or []
    if isinstance(rows, dict):
        rows = list(rows.values())

    def up(r):
        s = r.get("state")
        s = s.get("state") if isinstance(s, dict) else s
        return r.get("connected") is True or s in ("connected", "online", "ready", "up")

    return sum(1 for r in rows if isinstance(r, dict) and up(r)), (rows[0] if rows else None)


def cold_start(acpmux, peers, secs, keep):
    tmp = tempfile.mkdtemp(prefix="peercost-")
    fleet = Fleet(acpmux, tmp, peers)
    try:
        fleet.start_far()
        far_cpu0 = sum(tree_cpu(p.pid) for p in (fleet.sshd, fleet.far))
        near = fleet.start_near()
        t0 = time.time()
        peak_conc = peak_tunnels = peak_daemon_rss = 0
        seen, tunnel_rss = {}, {}
        series, all_up_at, sample_row = [], None, None
        last_rpc = 0
        while time.time() - t0 < secs:
            kids = children_map()
            live = [d for d in descendants(near.pid, kids) if (stat_of(d) or (0, 0, 0, ""))[3] == "ssh"]
            tun = 0
            for d in live:
                cl = cmdline(d)
                if " -W " in cl:
                    tun += 1
                    r = rss_kb(d)
                    if r:
                        tunnel_rss[d] = max(tunnel_rss.get(d, 0), r)
                seen[d] = True
            peak_conc, peak_tunnels = max(peak_conc, len(live)), max(peak_tunnels, tun)
            peak_daemon_rss = max(peak_daemon_rss, rss_kb(near.pid) or 0)
            now = time.time() - t0
            if now - last_rpc >= 1:
                last_rpc = now
                n_up, row = peers_up(fleet)
                sample_row = sample_row or row
                series.append((round(now, 1), len(live), n_up))
                if n_up is not None and n_up >= peers and all_up_at is None:
                    all_up_at = round(now, 1)
            time.sleep(0.05)
        near_cpu = tree_cpu(near.pid)
        own = stat_of(near.pid)
        far_cpu = sum(tree_cpu(p.pid) for p in (fleet.sshd, fleet.far)) - far_cpu0
        daemon_rss, hwm = rss_kb(near.pid), rss_kb(near.pid, "VmHWM")
        n_up, _ = peers_up(fleet)
        load = open("/proc/loadavg").read().split()[0]
        log = [l.split(" ", 2) for l in open(fleet.p("ssh.log")).read().splitlines()]
        spawned = len(log)
        tunnels = sum(1 for l in log if len(l) > 2 and " -W " in " " + l[2] + " ")
        rss = sorted(tunnel_rss.values())
        out = {
            "peers": peers, "secs": secs, "ssh_spawned": spawned, "ssh_tunnels": tunnels, "ssh_token_reads": spawned - tunnels,
            "peak_concurrent_ssh": peak_conc, "peak_concurrent_tunnels": peak_tunnels,
            "daemon_own_cpu_s": round(own[1], 2) if own else None,
            "total_cpu_s_near": round(near_cpu, 2), "far_cpu_s_sshd_and_far_daemon": round(far_cpu, 2),
            "daemon_rss_mb_final": round((daemon_rss or 0) / 1024, 1), "daemon_rss_mb_peak": round(max(hwm or 0, peak_daemon_rss) / 1024, 1),
            "ssh_tunnel_rss_mb_median": round(statistics.median(rss) / 1024, 2) if rss else None,
            "ssh_tunnel_rss_mb_max": round(rss[-1] / 1024, 2) if rss else None,
            "loadavg1_at_end": float(load), "peers_up_at_end": n_up, "all_peers_up_s": all_up_at, "series_s_ssh_up": series[:: max(1, len(series) // 20)],
            "peer_row_shape": sample_row,
        }
        if keep:
            out["tmp"] = tmp
        return out
    finally:
        fleet.stop()
        if not keep:
            shutil.rmtree(tmp, ignore_errors=True)


def timed_ssh(argv, hold=False, stdin_payload=b""):
    """One ssh run: (wall_s, cpu_s, rss_kb_while_idle). `hold`: keep the tunnel open to read its RSS."""
    t = time.monotonic()
    pr = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    rss = None
    if stdin_payload:
        pr.stdin.write(stdin_payload)
        pr.stdin.flush()
        pr.stdout.read1(1) if hasattr(pr.stdout, "read1") else pr.stdout.read(1)
    wall = time.monotonic() - t
    if hold:
        time.sleep(1.0)
        rss = rss_kb(pr.pid)
    pr.stdin.close()
    _, status, ru = os.wait4(pr.pid, 0)
    pr.returncode = 0
    return wall, ru.ru_utime + ru.ru_stime, rss


def phases(argv):
    """`ssh -vvv` stamped line by line: when each phase of one login begins, seconds since spawn."""
    t0 = time.monotonic()
    pr = subprocess.Popen(argv[:1] + ["-vvv"] + argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=False)
    marks = {}
    want = [("connect_start", rb"Connecting to"), ("tcp_connected", rb"Connection established"),
            ("banner", rb"Remote protocol version"), ("kexinit_sent", rb"SSH2_MSG_KEXINIT sent"),
            ("kex_reply", rb"SSH2_MSG_KEX_ECDH_REPLY|SSH2_MSG_KEX_DH_GEX_REPLY|SSH2_MSG_KEX_ECDH_REPLY received|expecting SSH2_MSG_KEX"),
            ("newkeys", rb"SSH2_MSG_NEWKEYS received"), ("auth_start", rb"SSH2_MSG_SERVICE_ACCEPT received"),
            ("authenticated", rb"Authenticated to"), ("channel_open", rb"Local connections to|channel 0: new|direct-tcpip")]
    kex = None
    pr.stdin.write(b"x")
    pr.stdin.flush()
    end = time.monotonic() + 8
    for line in pr.stderr:
        now = time.monotonic() - t0
        for name, pat in want:
            if name not in marks and re.search(pat, line):
                marks[name] = round(now * 1000, 1)
        m = re.search(rb"kex: algorithm: (\S+)", line)
        if m and not kex:
            kex = m.group(1).decode()
        if "channel_open" in marks or time.monotonic() > end:
            break
    time.sleep(0.2)
    pr.kill()
    pr.wait()
    return {"ms_since_spawn": marks, "kex": kex}


def handshake(acpmux, reps, real_host, keep):
    tmp = tempfile.mkdtemp(prefix="peercost-hs-")
    fleet = Fleet(acpmux, tmp, 1)
    try:
        fleet.start_far()
        port = fleet.ws_port
        tun = [fleet.p("bin", "ssh"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-W", f"127.0.0.1:{port}", "--", "peer001"]
        read = [fleet.p("bin", "ssh"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "peer001",
                "cat ~/.acpmux/config.json; printf '\\0'; cat ~/.acpmux/run/peer.token 2>/dev/null"]
        probe = b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        timed_ssh(tun, stdin_payload=probe)  # warm: known_hosts, page cache
        out = {"reps": reps, "kex": None}

        def batch(label, argv, payload):
            sshd0 = tree_cpu(fleet.sshd.pid)
            rows = [timed_ssh(argv, stdin_payload=payload) for _ in range(reps)]
            time.sleep(0.5)
            far = (tree_cpu(fleet.sshd.pid) - sshd0) / reps
            cpu = [r[1] for r in rows]
            out[label] = {"client_cpu_ms_median": round(statistics.median(cpu) * 1000, 1),
                          "client_cpu_ms_mean": round(statistics.mean(cpu) * 1000, 1),
                          "wall_ms_median": round(statistics.median(r[0] for r in rows) * 1000, 1),
                          "far_sshd_cpu_ms_per_login": round(far * 1000, 1)}

        batch("tunnel_login", tun, probe)
        batch("token_read_login", read, b"")
        idle = timed_ssh(tun, hold=True, stdin_payload=probe)
        out["idle_tunnel_rss_mb"] = round(idle[2] / 1024, 2) if idle[2] else None
        ph = phases(tun)
        out["phases"] = ph
        out["kex"] = ph["kex"]
        # CPU of the key exchange alone: a login that stops at the banner costs the TCP + version exchange only.
        if real_host:
            rt = [SSH, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-W", f"127.0.0.1:{SSH_PEER_PORT_DEFAULT}", "--", real_host]
            try:
                rows = [timed_ssh(rt, stdin_payload=probe) for _ in range(max(3, reps // 4))]
                out["real_host"] = {"client_cpu_ms_median": round(statistics.median(r[1] for r in rows) * 1000, 1),
                                    "wall_ms_median": round(statistics.median(r[0] for r in rows) * 1000, 1), "n": len(rows)}
            except Exception as e:  # noqa: BLE001 (a host that cannot be reached is a result)
                out["real_host"] = {"error": str(e)}
        return out
    finally:
        fleet.stop()
        if not keep:
            shutil.rmtree(tmp, ignore_errors=True)


SSH_PEER_PORT_DEFAULT = 47811


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["cold-start", "handshake", "both"])
    ap.add_argument("--acpmux", required=True, help="a release acpmux binary")
    ap.add_argument("--peers", type=int, default=130)
    ap.add_argument("--secs", type=int, default=60)
    ap.add_argument("--reps", type=int, default=20)
    ap.add_argument("--real-host", help="handshake: also time ssh -W to this host of the machine's own ssh config")
    ap.add_argument("--keep", action="store_true", help="keep the scratch directory (logs, configs)")
    ap.add_argument("--out", help="write the JSON here as well")
    a = ap.parse_args()
    result = {}
    if a.mode in ("cold-start", "both"):
        result["cold_start"] = cold_start(a.acpmux, a.peers, a.secs, a.keep)
    if a.mode in ("handshake", "both"):
        result["handshake"] = handshake(a.acpmux, a.reps, a.real_host, a.keep)
    rows = []
    cs, hs = result.get("cold_start"), result.get("handshake")
    if cs:
        for k in ("ssh_spawned", "peak_concurrent_ssh", "total_cpu_s_near", "daemon_rss_mb_peak", "ssh_tunnel_rss_mb_median"):
            rows.append({"name": f"acpmux.peer_cost.{k}", "value": cs[k], "peers": cs["peers"]})
    if hs:
        rows.append({"name": "acpmux.peer_cost.login_cpu_ms", "value": hs["tunnel_login"]["client_cpu_ms_median"]})
    for k, v in result.items():
        print(f"PEERCOST {k} {json.dumps(v, sort_keys=True)}")
    result["rows"] = rows
    if a.out:
        json.dump(result, open(a.out, "w"), indent=1)
    print(json.dumps({"rows": rows}))


if __name__ == "__main__":
    main()

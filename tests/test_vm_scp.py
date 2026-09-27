#!/usr/bin/env python3
"""Real OpenSSH/SFTP with an isolated guest directory and mock app control socket.

No Cloud account, provider token, system SSH config, or external network is used.
Run on macOS with the built CLI: python3 tests/test_vm_scp.py /path/to/cmux
The live Cloud test remains a separate merge gate.
"""
import concurrent.futures
import getpass
import json
import os
import pty
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time


def run(argv, **kwargs):
    return subprocess.run(argv, text=True, capture_output=True, timeout=45, **kwargs)


def drain_terminal(master, sink):
    """Collects a pty's output until every process holding its slave has exited."""
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            return
        if not chunk:
            return
        sink.extend(chunk)


def main(cli):
    with tempfile.TemporaryDirectory(prefix="scp-", dir="/tmp") as raw:
        root = Path(raw)
        guest = root / "guest"
        guest.mkdir()
        tools = root / "bin"
        tools.mkdir()
        key = root / "host"
        result = run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)])
        assert result.returncode == 0, result.stderr
        host_key = " ".join(key.with_suffix(".pub").read_text().split()[:2])
        sftp = "/usr/libexec/sftp-server"
        assert Path(sftp).is_file(), "macOS OpenSSH SFTP server is required"
        # The guest is Ubuntu. These two fixture adapters supply GNU utility
        # semantics on the Mac; file transfer and host authentication are real.
        (tools / "sha256sum").write_text(
            "#!/bin/sh\nif test -e " + shlex.quote(str(root / "corrupt")) +
            "; then echo 'wrong  -'; else exec /usr/bin/shasum -a 256 \"$@\"; fi\n")
        (tools / "mv").write_text(
            "#!/bin/sh\nif test \"$1\" = -fT; then shift; exec /bin/mv -f \"$@\"; fi\nexec /bin/mv \"$@\"\n")
        for path in tools.iterdir():
            path.chmod(0o700)
        wrapper = root / "command"
        wrapper.write_text(
            "#!/bin/sh\nset -eu\ncd " + shlex.quote(str(guest)) + "\n" +
            "export PATH=" + shlex.quote(str(tools)) + ":/usr/bin:/bin:/usr/sbin:/sbin\n" +
            'case "$SSH_ORIGINAL_COMMAND" in\n' + sftp +
            '*) exec ' + sftp + ' -d ' + shlex.quote(str(guest)) + ' ;;\n' +
            '*) exec /bin/sh -c "$SSH_ORIGINAL_COMMAND" ;;\nesac\n')
        wrapper.chmod(0o700)
        authorized = root / "authorized_keys"
        authorized.touch(mode=0o600)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        config = root / "sshd_config"
        config.write_text(f"""ListenAddress 127.0.0.1
Port {port}
HostKey {key}
PidFile {root}/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile {authorized}
StrictModes no
AllowUsers {getpass.getuser()}
Subsystem sftp {sftp}
LogLevel ERROR
""")
        server_log = (root / "sshd.log").open("w+")
        sshd = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stderr=server_log)
        app = socket.socket(socket.AF_UNIX)
        app.bind(str(root / "app.sock"))
        app.listen(16)
        app.settimeout(0.1)
        stop = threading.Event()
        lock = threading.Lock()
        requests = []
        wrong_host_key = False
        short_grant = False
        cleanup_grants_remaining = None
        idle_connection_closed = threading.Event()

        def serve_connection(conn):
            nonlocal short_grant, cleanup_grants_remaining
            # Match the app's bounded control-socket lifecycle. File transfer
            # can continue after its endpoint request's connection goes idle.
            conn.settimeout(2)
            with conn, conn.makefile("rwb") as stream:
                while True:
                    try:
                        line = stream.readline()
                    except (TimeoutError, socket.timeout):
                        idle_connection_closed.set()
                        return
                    if not line:
                        idle_connection_closed.set()
                        return
                    if line.startswith(b"auth "):
                        stream.write(b"OK\n")
                        stream.flush()
                        continue
                    request = json.loads(line)
                    with lock:
                        requests.append(request)
                    if request["method"] == "vm.scp_info":
                        if cleanup_grants_remaining is not None:
                            if cleanup_grants_remaining == 0:
                                return  # Drop only cleanup's grant response.
                            cleanup_grants_remaining -= 1
                            short_grant = True
                        public_key = request["params"]["public_key"].strip()
                        assert public_key.startswith("ssh-ed25519 ") and "\n" not in public_key
                        with lock, authorized.open("a") as out:
                            out.write(f'restrict,command="{wrapper}" {public_key}\n')
                            lifetime = 30 if short_grant else 900
                            short_grant = False
                        result = {
                            "host": "127.0.0.1", "port": port, "username": getpass.getuser(),
                            "host_public_key": public_key.rsplit(" ", 1)[0] if wrong_host_key else host_key,
                            "expires_at_unix": int(time.time()) + lifetime,
                        }
                        response = {"id": request["id"], "ok": True, "result": result}
                    elif request["method"] == "vm.file_transfer_failure":
                        params = request["params"]
                        assert set(params).issubset({"phase", "failure", "error_number"}), params
                        response = {"id": request["id"], "ok": True, "result": {"reference": "operation=test trace=00000000000000000000000000000001"}}
                    else:
                        response = {"id": request["id"], "ok": False, "error": {"code": "unexpected", "message": request["method"]}}
                    stream.write(json.dumps(response).encode() + b"\n")
                    stream.flush()

        def serve():
            while not stop.is_set():
                try:
                    conn, _ = app.accept()
                except socket.timeout:
                    continue
                threading.Thread(target=serve_connection, args=(conn,), daemon=True).start()

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        env.update(CMUX_SOCKET_PATH=str(root / "app.sock"), CMUX_CLI_SENTRY_DISABLED="1", CMUX_VM_PUSH_WATCH_ROUNDS="1")

        def push(local, remote, *args):
            return run([cli, "--json", "vm", "push", "test-vm", str(local), remote, *args], env=env)

        try:
            for _ in range(100):
                if sshd.poll() is not None:
                    server_log.seek(0)
                    raise AssertionError(server_log.read())
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.05)
            else:
                raise AssertionError("isolated SSH server did not start")
            payload = root / "payload.bin"
            payload.write_bytes(os.urandom(2_000_000))
            payload.chmod(0o751)
            remote = "new parent/a '$`% : file"
            result = push(payload, remote)
            assert result.returncode == 0, result.stderr
            assert (guest / remote).read_bytes() == payload.read_bytes()
            assert (guest / remote).stat().st_mode & 0o777 == 0o751
            print("PASS binary file, shell characters, missing parents, mode", flush=True)

            short_grant = True
            before_requests = len(requests)
            result = push(payload, "renewed/payload.bin")
            assert result.returncode == 0, result.stderr
            renewal = requests[before_requests:]
            assert len(renewal) == 2, "near-expiry grant was not renewed before finalization"
            assert renewal[0]["params"]["public_key"] == renewal[1]["params"]["public_key"]
            assert (guest / "renewed/payload.bin").read_bytes() == payload.read_bytes()
            assert not list(guest.rglob(".cmux-push.*"))
            print("PASS near-expiry grant renewed with the same key before finalization", flush=True)

            tree = root / "tree"
            tree.mkdir()
            (tree / "a").write_text("one")
            (tree / "node_modules").mkdir()
            (tree / "node_modules" / "skip").write_text("excluded")
            result = push(tree, "work/tree")
            assert result.returncode == 0, result.stderr
            assert (guest / "work/tree/a").read_text() == "one"
            assert not (guest / "work/tree/node_modules").exists()
            assert not list(guest.rglob(".cmux-push.*"))
            print("PASS directory, exclusions, one extraction, staging cleanup", flush=True)

            before = (guest / remote).read_bytes()
            (root / "corrupt").touch()
            result = push(payload, remote)
            assert result.returncode != 0, result.stdout
            assert (guest / remote).read_bytes() == before
            assert not list(guest.rglob(".cmux-push.*"))
            (root / "corrupt").unlink()
            print("PASS checksum failure preserves destination and removes staging", flush=True)

            wrong_host_key = True
            result = push(payload, "must-not-exist")
            assert result.returncode != 0 and "Host key verification failed" in result.stderr, result.stderr
            assert not (guest / "must-not-exist").exists()
            wrong_host_key = False
            print("PASS changed host key rejects transfer", flush=True)

            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                results = list(pool.map(lambda dest: push(payload, dest), ["parallel/a", "parallel/b"]))
            assert all(result.returncode == 0 for result in results), [r.stderr for r in results]
            assert (guest / "parallel/a").read_bytes() == (guest / "parallel/b").read_bytes() == payload.read_bytes()
            print("PASS concurrent transfers keep independent keys", flush=True)

            idle_connection_closed.clear()
            watch = subprocess.Popen([cli, "--json", "vm", "push", "test-vm", str(tree), "watch", "--watch", "--interval", "0.2"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                for _ in range(100):
                    if (guest / "watch/a").exists():
                        break
                    if watch.poll() is not None:
                        raise AssertionError(watch.communicate())
                    time.sleep(.1)
                # Wait for the server to retire the endpoint connection, then
                # make a new edit. The old test edited before the idle timeout.
                assert idle_connection_closed.wait(timeout=5), "control socket never reached its idle deadline"
                (tree / "b").write_text("two")
                stdout, stderr = watch.communicate(timeout=30)
                assert watch.returncode == 0, stderr
                events = [json.loads(line) for line in stdout.splitlines()]
                assert [event["sync"] for event in events] == [0, 1], events
                assert (guest / "watch/b").read_text() == "two"
            finally:
                if watch.poll() is None:
                    watch.kill()
                    watch.wait()
            assert all(r["method"] in {"vm.scp_info", "vm.file_transfer_failure"} for r in requests), requests
            failures = [r["params"] for r in requests if r["method"] == "vm.file_transfer_failure"]
            assert len(failures) == 2, failures
            assert {p["phase"] for p in failures} == {"process", "connect"}
            assert all(p["failure"] == "process" for p in failures), failures
            assert max(len(json.dumps(r)) for r in requests) < 1024
            print("PASS watch and bounded control messages without file bytes", flush=True)

            cleanup_grants_remaining = 2
            result = push(payload, "cleanup-failure/payload.bin")
            cleanup_grants_remaining = None
            assert result.returncode == 0, result.stderr
            assert (guest / "cleanup-failure/payload.bin").read_bytes() == payload.read_bytes()
            assert "cleanup failed" in result.stderr
            cleanup_reports = [r["params"] for r in requests if r["method"] == "vm.file_transfer_failure" and r["params"]["phase"] == "cleanup"]
            assert len(cleanup_reports) == 1, cleanup_reports
            assert cleanup_reports[0]["failure"] == "network", cleanup_reports
            assert "error_number" not in cleanup_reports[0]
            print("PASS cleanup grant transport failure keeps network classification and transfer success", flush=True)

            # SCP has no exec chunks. Verify human output over both a pipe and
            # a real terminal, with actual transfers and host-key rejection.
            for tty in (False, True):
                for fails in (False, True):
                    wrong_host_key = fails
                    destination = f"human-{tty}-{fails}"
                    master, slave = pty.openpty() if tty else (None, None)
                    terminal_output = bytearray()
                    reader = None
                    try:
                        process = subprocess.Popen(
                            [cli, "vm", "push", "test-vm", str(payload), destination],
                            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=slave if tty else subprocess.PIPE,
                        )
                        if slave is not None:
                            # The CLI owns the slave now. A terminal's output queue
                            # holds only about 1 KiB and the host-key failure report is
                            # longer, so the master must be drained while the CLI runs
                            # or its stderr writes block until the timeout.
                            os.close(slave)
                            slave = None
                            reader = threading.Thread(target=drain_terminal, args=(master, terminal_output), daemon=True)
                            reader.start()
                        try:
                            stdout, piped_stderr = process.communicate(timeout=30)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.communicate()
                            raise
                        if reader is not None:
                            # Returns once every process holding the slave has exited.
                            reader.join(timeout=10)
                            assert not reader.is_alive(), "terminal stderr stayed open after the CLI exited"
                        stderr = piped_stderr if piped_stderr is not None else bytes(terminal_output)
                    finally:
                        if slave is not None: os.close(slave)
                        if master is not None: os.close(master)
                        wrong_host_key = False
                    assert process.returncode == (1 if fails else 0), stderr
                    if fails:
                        assert b"Host key verification failed" in stderr, stderr
                        assert b"Cloud diagnostic reference:" in stderr, stderr
                        assert b"Pushed" not in stdout, stdout
                        assert not (guest / destination).exists()
                    else:
                        assert b"Pushed" in stdout and destination.encode() in stdout, stdout
                        assert stderr == b"", stderr
                        assert (guest / destination).read_bytes() == payload.read_bytes()
            print("PASS SCP human output and errors over pipes and terminals", flush=True)
        finally:
            stop.set()
            thread.join(timeout=2)
            app.close()
            sshd.terminate()
            sshd.wait(timeout=10)
            server_log.close()


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))

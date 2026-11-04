"""Exercise a real upload CLI killed mid-transfer, then its exact-directory cleanup."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="upload-cancel-proof-") as scratch:
    base = Path(scratch)
    pastes = Path(tempfile.gettempdir()) / "cmux-pastes"
    pastes.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cancel-proof-", dir=pastes) as sources:
        source = Path(sources) / "large.bin"
        with source.open("wb") as file:
            file.truncate(32 * 1024 * 1024 + 1)
        listener = socket.socket(socket.AF_UNIX)
        endpoint = str(base / "d.sock")
        listener.bind(endpoint)
        listener.listen()
        listener.settimeout(90)
        wrote = threading.Event()
        release = threading.Event()
        errors = []
        files = {"/work/local/uploads/ffffffffffffffffffffffffffffffff/keep.bin": 7}
        dirs = {"/", "/work"}
        requests = []

        def machine():
            try:
                # Upload identify + transfer, then cleanup identify + delete.
                for _ in range(4):
                    stream, _ = listener.accept()
                    with stream, stream.makefile("rb") as reader:
                        for line in reader:
                            request = json.loads(line)
                            command = request["cmd"]
                            path = request.get("path", "")
                            requests.append((command, path))
                            if command == "identify":
                                data = {"capabilities": ["fs-v1"]}
                            elif command == "fs.stat":
                                if path not in dirs and path not in files:
                                    stream.sendall((json.dumps({"id": request["id"], "ok": False, "error_code": "fs.not_found"}) + "\n").encode())
                                    continue
                                data = {"kind": "dir" if path in dirs else "file"}
                            elif command == "fs.mkdir":
                                dirs.add(path.rstrip("/") + "/" + request["name"])
                                data = {"entry": {}}
                            elif command == "fs.write":
                                text = request["bytes_base64"]
                                size = len(text) // 4 * 3 - (len(text) - len(text.rstrip("=")))
                                files[path] = files.get(path, 0) + size if request["mode"] == "append" else size
                                wrote.set()
                                if not release.wait(60):
                                    raise RuntimeError("proof did not release the blocked write")
                                data = {"entry": {"revision": "r1"}}
                            elif command == "fs.delete":
                                for target in request["paths"]:
                                    for item in list(files):
                                        if item == target or item.startswith(target + "/"):
                                            del files[item]
                                    dirs.difference_update({item for item in dirs if item == target or item.startswith(target + "/")})
                                data = {}
                            else:
                                raise RuntimeError(f"unexpected command {command}")
                            try:
                                stream.sendall((json.dumps({"id": request["id"], "ok": True, "data": data}) + "\n").encode())
                            except BrokenPipeError:
                                break
            except BaseException as error:
                errors.append(error)

        worker = threading.Thread(target=machine)
        worker.start()
        identity = "0123456789abcdef0123456789abcdef"
        args = ["--socket", endpoint, "--remote-root", "/work", "--upload-id", identity]
        child = subprocess.Popen([binary, "link", "access", "upload", *args, str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert wrote.wait(60), "real CLI never wrote a chunk"
            partial = [path for path in files if identity in path]
            assert len(partial) == 1 and partial[0].endswith(".cmux-sync-part"), files
            child.kill()
            child.communicate(timeout=10)
            assert child.returncode == -9, child.returncode
            release.set()
            cleaned = subprocess.run([binary, "link", "access", "upload-cancel", *args], capture_output=True, text=True, timeout=90)
            assert cleaned.returncode == 0, (cleaned.stdout, cleaned.stderr)
            worker.join(timeout=90)
            assert not worker.is_alive(), "fake daemon did not finish"
            assert not errors, errors
            assert files == {"/work/local/uploads/ffffffffffffffffffffffffffffffff/keep.bin": 7}, files
            assert not any(identity in path for path in dirs), dirs
            print(json.dumps({"result": "PASS", "source_bytes": source.stat().st_size, "killed_status": child.returncode, "partial_before": partial, "files_after": files, "cleanup": json.loads(cleaned.stdout.splitlines()[-1]), "requests": requests}))
        finally:
            release.set()
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
            listener.close()

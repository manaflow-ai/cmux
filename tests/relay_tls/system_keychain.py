#!/usr/bin/env python3
"""Exercise the app's pinned Iroh binary against a disposable System-keychain CA.

Requires an isolated macOS runner and explicit --allow-system-keychain. The
generated CA is removed in finally; no existing certificate is modified.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
KEYCHAIN = "/Library/Keychains/System.keychain"


def run(*args, **kwargs):
    print(f"Running {args[0]} {args[1]}", flush=True)
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=60, **kwargs).stdout


def certificates(directory):
    subject = "cmux-12714-" + uuid.uuid4().hex
    config = directory / "openssl.cnf"
    config.write_text(f"""[req]
distinguished_name = dn
prompt = no
[dn]
CN = {subject}
[ca_ext]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[ca]
default_ca = issuer
[issuer]
database = {directory}/index.txt
serial = {directory}/serial
new_certs_dir = {directory}
certificate = {directory}/root.pem
private_key = {directory}/root.key
default_md = sha256
default_days = 2
policy = policy
unique_subject = no
[policy]
commonName = supplied
""")
    (directory / "index.txt").touch()
    (directory / "serial").write_text("01\n")
    run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
        "-config", str(config), "-extensions", "ca_ext",
        "-keyout", str(directory / "root.key"), "-out", str(directory / "root.pem"))
    for name, hostname in [("valid", "localhost"), ("wrong-host", "wrong.example"),
                           ("expired", "localhost")]:
        ext = directory / f"{name}.ext"
        ext.write_text(f"[leaf_ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                       f"extendedKeyUsage=serverAuth\nsubjectAltName=DNS:{hostname}\n")
        run("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
            "-subj", f"/CN={hostname}", "-keyout", str(directory / f"{name}.key"),
            "-out", str(directory / f"{name}.csr"))
        dates = ["-startdate", "20200101000000Z", "-enddate", "20200102000000Z"] if name == "expired" else []
        run("openssl", "ca", "-batch", "-notext", "-config", str(config), "-extfile", str(ext),
            "-extensions", "leaf_ext",
            "-in", str(directory / f"{name}.csr"), "-out", str(directory / f"{name}.pem"), *dates)
    return subject


def build_client(directory, output, diagnostics):
    """Build the probe with the app's locked revision and reject resolver drift."""
    lockfile = ROOT / "Packages/Shared/CmuxIrohTransport/Package.resolved"
    pins = json.loads(lockfile.read_text())["pins"]
    pin = next(pin for pin in pins if pin["identity"] == "iroh-ffi")
    state = pin["state"]
    version = state.get("version")
    if version is not None:
        dependency = f'.package(url: {json.dumps(pin["location"])}, exact: {json.dumps(version)})'
        description = version
    else:
        revision = state.get("revision")
        if not revision:
            raise RuntimeError("Iroh lockfile pin has neither a version nor a revision")
        dependency = f'.package(url: {json.dumps(pin["location"])}, revision: {json.dumps(revision)})'
        description = f"revision {revision}"
    (directory / "Package.swift").write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RelayTLSClient", platforms: [.macOS(.v14)],
    dependencies: [{dependency}],
    targets: [.executableTarget(name: "RelayTLSClient",
        dependencies: [.product(name: "IrohLib", package: "iroh-ffi")], path: "Sources")])
''')
    sources = directory / "Sources"
    sources.mkdir()
    shutil.copyfile(lockfile, directory / "Package.resolved")
    shutil.copyfile(Path(__file__).with_name("RelayTLSClient.swift"), sources / "RelayTLSClient.swift")
    print(f"Building pinned Iroh {description}", flush=True)
    with (output / "build.log").open("w") as log:
        flags = ["-Xswiftc", "-DRELAY_TLS_DIAGNOSTICS"] if diagnostics else []
        build = subprocess.run(["swift", "build", "--package-path", str(directory), *flags],
                               stdout=log, stderr=subprocess.STDOUT, timeout=300)
    if build.returncode:
        raise RuntimeError((output / "build.log").read_text())
    resolved = json.loads((directory / "Package.resolved").read_text())["pins"]
    actual = next(value for value in resolved if value["identity"] == "iroh-ffi")
    if actual["state"] != pin["state"] or actual["location"] != pin["location"]:
        raise RuntimeError("Test framework resolution drifted from the app's lockfile")
    return directory / ".build/debug/RelayTLSClient", pin


def handshake(client, directory, name, label, output, diagnostics=True):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(directory / f"{name}.pem", directory / f"{name}.key")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    listener.settimeout(0.2)
    observed = {}
    handshake_observed = threading.Event()
    stop = threading.Event()

    def serve():
        while not stop.is_set():
            try:
                stream, _ = listener.accept()
            except socket.timeout:
                continue
            stream.settimeout(3)
            try:
                with context.wrap_socket(stream, server_side=True) as tls:
                    # A TLS 1.3 server handshake can finish before the client's
                    # certificate alert. Application data proves validation.
                    data = tls.recv(4096)
                    observed["accepted"] = observed.get("accepted", False) or data.startswith(b"GET ")
                    tls.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            except (ssl.SSLError, OSError) as error:
                observed.setdefault("accepted", False)
                observed["server_error"] = type(error).__name__
                stream.close()
            finally:
                handshake_observed.set()

    server = threading.Thread(target=serve)
    server.start()
    log = output / f"{label}.log"
    with log.open("w") as log_file:
        process = subprocess.Popen([str(client), f"https://localhost:{listener.getsockname()[1]}/"],
                                   stdin=subprocess.PIPE, stdout=log_file, stderr=log_file)
        try:
            handshake_observed.wait(timeout=20)
            # Observe the native error callback before closing the endpoint.
            # The TLS server's alert can arrive before Iroh updates its state.
            deadline = time.monotonic() + 30
            while diagnostics and time.monotonic() < deadline and process.poll() is None:
                if "DIAGNOSTIC " in log.read_text():
                    break
                time.sleep(0.05)
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            stop.set()
            server.join(timeout=5)
            listener.close()
    if server.is_alive() or not observed:
        raise RuntimeError(f"{label}: no TLS result; inspect {log}")
    observed["case"] = label
    diagnostics = [json.loads(line.removeprefix("DIAGNOSTIC "))
                   for line in log.read_text().splitlines() if line.startswith("DIAGNOSTIC ")]
    observed["diagnostics"] = diagnostics
    observed["final_diagnostics"] = [json.loads(line.removeprefix("FINAL_DIAGNOSTIC "))
                                     for line in log.read_text().splitlines()
                                     if line.startswith("FINAL_DIAGNOSTIC ")]
    print(json.dumps(observed), flush=True)
    return observed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-system-keychain", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--diagnostics", action="store_true", help="also verify native failure categories (requires the fixed framework)")
    args = parser.parse_args()
    if sys.platform != "darwin" or not args.allow_system_keychain:
        parser.error("use an isolated macOS runner with --allow-system-keychain")
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cmux-relay-tls-") as temp:
        directory = Path(temp)
        os.chmod(directory, 0o700)
        subject = certificates(directory)
        client, pin = build_client(directory, args.output, args.diagnostics)
        root = directory / "root.pem"
        der = subprocess.check_output(["openssl", "x509", "-in", str(root), "-outform", "DER"])
        fingerprint = hashlib.sha1(der).hexdigest().upper()
        results = []
        try:
            results.append(handshake(client, directory, "valid", "untrusted-issuer", args.output, args.diagnostics))
            run("sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot",
                "-p", "ssl", "-k", KEYCHAIN, str(root))
            run("security", "verify-cert", "-c", str(directory / "valid.pem"),
                "-p", "ssl", "-s", "localhost")
            results.append(handshake(client, directory, "valid", "system-trusted-enterprise-root", args.output, args.diagnostics))
            results.append(handshake(client, directory, "wrong-host", "hostname-mismatch", args.output, args.diagnostics))
            results.append(handshake(client, directory, "expired", "expired-certificate", args.output, args.diagnostics))
        finally:
            (args.output / "handshakes.json").write_text(json.dumps(results, indent=2) + "\n")
            cleanup_errors = []
            for command in [
                ["sudo", "-n", "security", "remove-trusted-cert", "-d", str(root)],
                ["sudo", "-n", "security", "delete-certificate", "-Z", fingerprint, KEYCHAIN],
            ]:
                print(f"Cleanup: {command[3]}", flush=True)
                try:
                    cleanup_result = subprocess.run(
                        command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, check=False, timeout=15
                    )
                    if cleanup_result.returncode not in (0, 44):
                        cleanup_errors.append((command[3], cleanup_result.returncode))
                except subprocess.TimeoutExpired:
                    print(f"Cleanup command timed out: {command[3]}", flush=True)
                    cleanup_errors.append((command[3], "timeout"))
        results.append(handshake(client, directory, "valid", "removed-root", args.output, args.diagnostics))
        lookup = subprocess.run(["security", "find-certificate", "-c", subject, KEYCHAIN],
                                capture_output=True, check=False, timeout=15)
        # security exits with errSecItemNotFound (-25300 modulo 256), not an
        # arbitrary failure: a locked/unreadable keychain is not cleanup proof.
        cleanup = lookup.returncode == 44 and not lookup.stdout
        if cleanup_errors:
            print(f"Cleanup warnings: {cleanup_errors}", flush=True)
        report = {"framework": pin, "macos": run("sw_vers", "-productVersion").strip(),
                  "results": results, "root_removed": cleanup,
                  "root_lookup_exit": lookup.returncode, "cleanup_errors": cleanup_errors}
        (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        expected = [False, True, False, False, False]
        if [result["accepted"] for result in results] != expected or not cleanup:
            raise SystemExit("FAIL: system trust or certificate validation did not match the contract")
        for result, cause in zip(results, ["unknownIssuer", None, "hostnameMismatch",
                                           "certificateExpired", "unknownIssuer"]):
            for source in ["diagnostics", "final_diagnostics"]:
                if args.diagnostics and cause and not any(item["cause"] == cause for item in result[source]):
                    raise SystemExit(f"FAIL: {result['case']} lost the native {cause} in {source}")
                if any(item["host"] != "localhost" for item in result[source]):
                    raise SystemExit("FAIL: diagnostic did not identify the TLS host")
        print("PASS: System-keychain root honored; untrusted issuer, wrong host, expired and removed root rejected")


if __name__ == "__main__":
    main()

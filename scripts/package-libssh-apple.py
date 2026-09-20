#!/usr/bin/env python3
"""Package verified Apple SSH archives for the native Swift package."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile

class AppleSSHArchivePackager:
    def run(self):
        parser = argparse.ArgumentParser()
        parser.add_argument("--macos", type=pathlib.Path, required=True)
        parser.add_argument("--simulator", type=pathlib.Path, required=True)
        parser.add_argument("--device", type=pathlib.Path, required=True)
        parser.add_argument("--output", type=pathlib.Path, required=True)
        args = parser.parse_args()
        if args.output.exists():
            parser.error("Output exists; use a fresh artifact destination.")
        inputs = [(args.macos, "macosx"), (args.simulator, "iphonesimulator"), (args.device, "iphoneos")]
        receipts = {}
        for root, sdk in inputs:
            data = json.loads(root.joinpath("build-metadata.json").read_text())
            if data["sdk"] != sdk or data["arch"] != "arm64" or not data.get("fullArchiveLinkVerified"):
                parser.error("Archive lacks target-platform link evidence.")
            if data["libsshVersion"] != "0.12.2" or data["mbedtlsVersion"] != "3.6.7" or data.get("sanitizers"):
                parser.error("Unsupported version or instrumented shipping archive.")
            for name, receipt in data["staticArchives"].items():
                if hashlib.sha256(root.joinpath(name).read_bytes()).hexdigest() != receipt["sha256"]:
                    parser.error("Archive checksum no longer matches its receipt.")
            receipts[sdk] = data
        with tempfile.TemporaryDirectory(prefix="cmux-ssh-package-") as temporary:
            stage = pathlib.Path(temporary)
            command = ["xcodebuild", "-create-xcframework"]
            for root, sdk in inputs:
                item = stage/sdk
                headers = item/"Headers"
                headers.mkdir(parents=True)
                shutil.copytree(root/"libssh", headers/"libssh")
                headers.joinpath("cmux_ssh_backend.h").write_text("#include <libssh/libssh.h>\n")
                headers.joinpath("module.modulemap").write_text(
                    'module CmuxSSHBackend { header "cmux_ssh_backend.h" export * }\n'
                )
                archive = item/"libCmuxSSHBackend.a"
                subprocess.run(["xcrun", "libtool", "-static", "-o", str(archive),
                                *map(str, sorted(root.glob("*.a")))], check=True)
                command.extend(["-library",str(archive),"-headers",str(headers)])
            args.output.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(command+["-output",str(args.output.resolve())],check=True)
        args.output.with_suffix(".receipt.json").write_text(json.dumps(receipts,indent=2)+"\n")

if __name__ == "__main__":
    AppleSSHArchivePackager().run()

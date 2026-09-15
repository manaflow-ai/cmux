#!/usr/bin/env python3
"""Validate or restore VPN entitlements after exporting an unsigned archive.

Xcode signs each target locally. This preserves those signatures' other
entitlements and fails if the profiles do not authorize the VPN capability.
No certificates or profiles are copied to a builder.
"""

import argparse
import fnmatch
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile

NETWORK_EXTENSION = "com.apple.developer.networking.networkextension"


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def required_entitlements(profile, signed, bundle_id, host_id, is_host):
    app_id = profile.get("application-identifier", "")
    prefix, separator, identifier = app_id.partition(".")
    if not separator or identifier != bundle_id:
        raise ValueError("Profile does not match the exact bundle identifier")
    if "packet-tunnel-provider" not in profile.get(NETWORK_EXTENSION, []):
        raise ValueError("Regenerate the profile with Network Extensions enabled")
    group = f"{prefix}.{host_id}"
    groups = [group, group + ".cloud-vpn"] if is_host else [group + ".cloud-vpn"]
    for value in groups:
        if not any(fnmatch.fnmatchcase(value, pattern) for pattern in profile.get("keychain-access-groups", [])):
            raise ValueError("Profile does not authorize the Cloud VPN Keychain group")
    result = dict(signed)
    if result.get("application-identifier") != app_id:
        raise ValueError("Signed application identifier does not match the profile")
    result[NETWORK_EXTENSION] = ["packet-tunnel-provider"]
    result["keychain-access-groups"] = groups
    return result


def validate_or_repair(app, repair):
    extension = app / "PlugIns/cmuxTunnelExtension.appex"
    if not extension.is_dir():
        raise ValueError("Cloud VPN extension is missing from the app")
    host_info = plistlib.loads((app / "Info.plist").read_bytes())
    host_id = host_info["CFBundleIdentifier"]
    plans = []
    # Inner bundle first, so the host's final signature covers its signature.
    for bundle, is_host in [(extension, False), (app, True)]:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        expected_id = host_id if is_host else host_id + ".tunnel"
        if info["CFBundleIdentifier"] != expected_id:
            raise ValueError("Cloud VPN extension has the wrong bundle identifier")
        profile = plistlib.loads(run("security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")))
        signed = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", "--xml", str(bundle)))
        desired = required_entitlements(profile["Entitlements"], signed, expected_id, host_id, is_host)
        if is_host:
            info["CMUXKeychainAccessGroup"] = desired["keychain-access-groups"][0]
        plans.append((bundle, profile, signed, desired, info))

    if plans[0][3]["keychain-access-groups"] != [plans[1][3]["keychain-access-groups"][-1]]:
        raise ValueError("App and extension profiles do not share the same VPN Keychain group")

    if repair:
        with tempfile.TemporaryDirectory(prefix="cmux-vpn-signing-") as directory:
            temporary = Path(directory)
            for index, (bundle, profile, signed, desired, info) in enumerate(plans):
                cert_prefix = temporary / f"certificate-{index}-"
                run("codesign", "-d", f"--extract-certificates={cert_prefix}", str(bundle))
                certificate = Path(str(cert_prefix) + "0").read_bytes()
                if certificate not in profile["DeveloperCertificates"]:
                    raise ValueError("Signing certificate is absent from the profile")
                identity = hashlib.sha1(certificate).hexdigest()
                entitlements = temporary / f"entitlements-{index}.plist"
                entitlements.write_bytes(plistlib.dumps(desired))
                (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
                timestamp = "--timestamp=none" if signed.get("get-task-allow") else "--timestamp"
                run("codesign", "--force", "--sign", identity, "--entitlements", str(entitlements), timestamp, str(bundle))
        # Read signatures again. Never treat a successful codesign exit as proof.
        validate_or_repair(app, False)
        return

    for bundle, _, signed, desired, info in plans:
        if signed != desired:
            raise ValueError(f"VPN entitlements missing or incorrect in {bundle.name}")
        actual_info = plistlib.loads((bundle / "Info.plist").read_bytes())
        if actual_info != info:
            raise ValueError("The app's runtime Keychain group does not match its signature")
        run("codesign", "--verify", "--strict", str(bundle))
    print("Cloud VPN signing verified: distinct app/extension IDs, private shared Keychain group, packet tunnel entitlement")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--repair", action="store_true")
    args = parser.parse_args()
    try:
        validate_or_repair(args.app, args.repair)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Cloud VPN signing failed: {error}\n")

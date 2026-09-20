#!/bin/bash
set -euo pipefail
sdk="${1:-iphonesimulator}"
arch="${2:-arm64}"
deployment_target="${3:-17.0}"
output="${4:-artifacts/ios-remote-access/libssh-${sdk}-${arch}}"
case "$sdk" in iphonesimulator|iphoneos|macosx) ;; *) echo "unsupported SDK: $sdk" >&2; exit 2 ;; esac
for command in cmake ninja curl shasum python3 xcrun; do command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 2; }; done
system_name=iOS
[[ "$sdk" != macosx ]] || system_name=Darwin
san_flags=""
[[ "${CMUX_SSH_SANITIZERS:-0}" != 1 ]] || san_flags="-fsanitize=address,undefined -fno-omit-frame-pointer"
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$output" in /*) ;; *) output="$root/$output" ;; esac
[[ ! -e "$output" ]] || { echo "Output already exists" >&2; exit 2; }
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-libssh.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
libssh_archive="libssh-0.12.2.tar.xz"
libssh_sha256="49560f677d96e3706a904ac2de1116e25f3680937d51e5c92198fcba4a1c1e9f"
mbedtls_archive="mbedtls-3.6.7.tar.bz2"
mbedtls_sha256="a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6"
download() {
  curl --fail --location --retry 3 --silent --show-error "$1" --output "$2"
  printf '%s  %s\n' "$3" "$2" | shasum -a 256 -c -
}
download "https://www.libssh.org/files/0.12/$libssh_archive" "$work/$libssh_archive" "$libssh_sha256"
download "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.7/$mbedtls_archive" "$work/$mbedtls_archive" "$mbedtls_sha256"
mkdir "$work/libssh-src" "$work/mbedtls-src"
tar -xf "$work/$libssh_archive" --strip-components=1 -C "$work/libssh-src"
tar -xf "$work/$mbedtls_archive" --strip-components=1 -C "$work/mbedtls-src"
python3 - "$work/mbedtls-src/include/mbedtls/mbedtls_config.h" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace("//#define MBEDTLS_THREADING_C", "#define MBEDTLS_THREADING_C")
s = s.replace("//#define MBEDTLS_THREADING_PTHREAD", "#define MBEDTLS_THREADING_PTHREAD")
p.write_text(s)
PY
sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
mkdir "$work/mbedtls-build"
cmake -S "$work/mbedtls-src" -B "$work/mbedtls-build" -G Ninja -DCMAKE_SYSTEM_NAME="$system_name" -DCMAKE_C_FLAGS="$san_flags" -DCMAKE_OSX_SYSROOT="$sdk_path" -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" -DCMAKE_TRY_COMPILE_TARGET_TYPE=EXECUTABLE -DCMAKE_BUILD_TYPE=Release -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DMBEDTLS_FATAL_WARNINGS=OFF -DCMAKE_INSTALL_PREFIX="$work/mbedtls-install"
cmake --build "$work/mbedtls-build" --parallel 4
cmake --install "$work/mbedtls-build"
mkdir "$work/libssh-build"
cmake -S "$work/libssh-src" -B "$work/libssh-build" -G Ninja -DCMAKE_SYSTEM_NAME="$system_name" -DCMAKE_C_FLAGS="$san_flags" -DCMAKE_OSX_SYSROOT="$sdk_path" -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" -DCMAKE_TRY_COMPILE_TARGET_TYPE=EXECUTABLE -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWITH_SERVER=OFF -DWITH_EXAMPLES=OFF -DWITH_GSSAPI=OFF -DWITH_ZLIB=OFF -DWITH_FIDO2=OFF -DWITH_PKCS11_URI=OFF -DWITH_PCAP=OFF -DWITH_NACL=OFF -DUNIT_TESTING=OFF -DCLIENT_TESTING=OFF -DWITH_BENCHMARKS=OFF -DWITH_SYMBOL_VERSIONING=OFF -DWITH_DEBUG_CALLTRACE=OFF -DWITH_EXEC=OFF -DWITH_MBEDTLS=ON -DMBEDTLS_INCLUDE_DIR="$work/mbedtls-src/include" -DMBEDTLS_SSL_LIBRARY="$work/mbedtls-install/lib/libmbedtls.a" -DMBEDTLS_CRYPTO_LIBRARY="$work/mbedtls-install/lib/libmbedcrypto.a" -DMBEDTLS_X509_LIBRARY="$work/mbedtls-install/lib/libmbedx509.a" -DCMAKE_INSTALL_PREFIX="$work/libssh-install"
cmake --build "$work/libssh-build" --parallel 4
cmake --install "$work/libssh-build"
mkdir -p "$output"
cp "$work/libssh-install/lib/libssh.a" "$output/"
for archive in mbedcrypto mbedx509 mbedtls everest p256m; do
  cp "$work/mbedtls-install/lib/lib$archive.a" "$output/"
done
cp -R "$work/libssh-install/include/libssh" "$output/"
cp -R "$work/mbedtls-install/include/mbedtls" "$output/"
cp -R "$work/mbedtls-install/include/psa" "$output/"
python3 - "$output" "$sdk" "$arch" "$deployment_target" "$libssh_sha256" "$mbedtls_sha256" "$san_flags" <<'PY'
import hashlib, json, pathlib, sys
out, sdk, arch, deployment, libssh_sha, mbedtls_sha, sanitizers = sys.argv[1:]
files = {}
for path in sorted(pathlib.Path(out).rglob("*.a")):
    files[path.name] = {"bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
pathlib.Path(out, "build-metadata.json").write_text(json.dumps({"sdk": sdk, "arch": arch, "deploymentTarget": deployment, "libsshVersion": "0.12.2", "libsshSourceSHA256": libssh_sha, "mbedtlsVersion": "3.6.7", "mbedtlsSourceSHA256": mbedtls_sha, "staticArchives": files, "serverSupport": False, "gssapiSupport": False, "fido2Support": False, "pkcs11Support": False, "sftpSupport": True, "sanitizers": sanitizers}, indent=2) + "\n")
PY

# Static-only function probes are forbidden: they accept nonexistent symbols.
# Force-load every SSH object so an archive cannot falsely pass with unresolved APIs.
cp "$work/libssh-build/config.h" "$output/libssh-config.h"
cp "$work/libssh-src/COPYING" "$output/libssh-COPYING"
cp "$work/mbedtls-src/LICENSE" "$output/mbedtls-LICENSE"
python3 - "$output" "$sdk" "$arch" "$deployment_target" "$san_flags" <<'PY'
from pathlib import Path
import json, subprocess, sys
out=Path(sys.argv[1]); sdk,arch,deployment,sanitizers=sys.argv[2:]
source=out/"link-smoke.c"
source.write_text("#include <libssh/libssh.h>\nint main(void) { ssh_session s=ssh_new(); ssh_free(s); return 0; }\n")
sdk_path=subprocess.check_output(["xcrun","--sdk",sdk,"--show-sdk-path"],text=True).strip()
minimum={"iphonesimulator":"-mios-simulator-version-min=", "iphoneos":"-miphoneos-version-min=", "macosx":"-mmacosx-version-min="}[sdk]+deployment
subprocess.run(["xcrun","--sdk",sdk,"clang",*sanitizers.split(),"-arch",arch,"-isysroot",sdk_path,minimum,
                "-I",str(out),str(source),"-Wl,-force_load,"+str(out/"libssh.a"),
                *map(str, sorted(out.glob("libmbed*.a"))), str(out/"libeverest.a"),
                str(out/"libp256m.a"),"-o",str(out/"link-smoke")],check=True)
platform=subprocess.check_output(["xcrun","vtool","-show-build",str(out/"link-smoke")],text=True)
out.joinpath("link-platform.txt").write_text(platform)
expected={"iphonesimulator":"IOSSIMULATOR", "iphoneos":"IOS", "macosx":"MACOS"}[sdk]
assert f"platform {expected}\n" in platform, platform
metadata=json.loads(out.joinpath("build-metadata.json").read_text())
metadata.update(fullArchiveLinkVerified=True, protocolRuntimeVerified=False, localCommandExecution=False)
out.joinpath("build-metadata.json").write_text(json.dumps(metadata,indent=2)+"\n")
PY

echo "Built and link-checked experimental SSH client stack: $output"

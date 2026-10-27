# cmux-next on Linux

Scripts that let the pure-Swift packages and the oracle tools build and run on an
Ubuntu 24.04 host, such as the 360-core VM ([p15-oracle](../../../plans/cmux-next/chrome-parity/p15-oracle.md)).
They do not build the macOS app.

## setup-swift.sh

Installs the Swift toolchain that the Linux package job in CI uses. It uses
[swiftly](https://www.swift.org/install/linux/) and does not need root, except for apt.

```bash
scripts/cmux-next/linux/setup-swift.sh           # install or repair; prints each change
scripts/cmux-next/linux/setup-swift.sh --check   # change nothing; exit 1 if a change is needed
. ~/.local/share/swiftly/env.sh                  # put swift on PATH in this shell
swift build --package-path Packages/Shared/CMUXAuthCore
```

### Which version

The script reads the version from files. The version is not written in the script.

1. **CI pin (used).** This is the `swift:<major.minor>-noble@sha256:...` container in
   [`.github/workflows/swift-packages-linux.yml`](../../../.github/workflows/swift-packages-linux.yml).
   The tag gives only major.minor. The script reads the patch release (`SWIFT_VERSION` in the
   image config) for the pinned digest from the registry, and does not pull the image. An x.y.0
   image says only `x.y`; the script uses `x.y.0`. When the value is a release of the tag's
   major.minor, the script keeps it in `~/.cache/cmux/swift-image/<digest>-<arch>`, so a later
   run does not use the network. `--check` does not write the cache.
2. **hq pin (compared).** This is `SWIFT_VERSION` in cmuxterm-hq
   `build-fleet/swift-linux-builder/setup.sh`, read from `origin/main` of the hq checkout
   (`$CMUX_HQ`, a `cmuxterm-hq` folder next to the clone, or `~/fun`, `~`, `~/Projects`).
   That builder runs a patched Swift 6.3.3 to cross-compile the macOS app. The package tests
   pass in CI on the workflow's toolchain, so the script uses the CI pin and prints the hq
   version when the two are different.

On 2026-10-25 the CI pin was Swift 6.2.4 and the hq pin was 6.3.3.
To move to a new version, change the workflow image. Do not change this script.

### What it installs

- These apt packages, when they are missing: the swift.org Ubuntu 24.04 toolchain dependencies
  (the list from hq `setup.sh`), and `libsqlite3-dev`, `zlib1g-dev`, `libcurl4-openssl-dev`
  and `libxml2-dev`.
- swiftly in `$SWIFTLY_HOME_DIR` (default `~/.local/share/swiftly`). The script checks the
  tarball's signature against the swift.org keys. It does not change your shell profile.
- The pinned toolchain, as swiftly's global default. swiftly verifies the toolchain signature.

Each step checks first and downloads only when something is missing. A second run changes
nothing and prints `0 change(s) made`. The script runs swiftly from `/`. Thus it never writes
a `.swift-version` file into the checkout.

### Overrides

| Variable | Effect |
| --- | --- |
| `CMUX_HQ` | Path to the cmuxterm-hq checkout that gives the hq pin |
| `SWIFTLY_HOME_DIR`, `SWIFTLY_BIN_DIR`, `SWIFTLY_TOOLCHAINS_DIR` | swiftly's own locations |
| `XDG_CACHE_HOME` | Parent of the image-version cache |

## String tables (compile-xcstrings.py)

On Linux, SwiftPM copies a `.xcstrings` catalog into the bundle as JSON, and Foundation
cannot read it. The Linux mode of the CmuxNext manifest (`CMUX_SWIFTPM_TARGET_LINUX=1`)
therefore gives every target with a catalog a `LinuxStringTables` resource. That folder
holds the compiled `<lang>.lproj/<table>.strings` files. When the folder is missing, SwiftPM
stops before it compiles any Swift, so a build without the tables reports no Swift errors.

`swift-tier.sh` compiles the tables into its source copy before every SwiftPM command. You do
not run a step first. The script gets the targets and their folders from the Linux-mode
`swift package dump-package`. It writes only the tables that changed.

For a SwiftPM run without `swift-tier.sh`, compile the tables first:

```bash
python3 -I scripts/cmux-next/linux/compile-xcstrings.py           # write tables and links in the checkout
python3 -I scripts/cmux-next/linux/compile-xcstrings.py --check   # change nothing; exit 1 if stale
```

The tables go to `Packages/macOS/CmuxNext/.build-linux/lproj/<Target>/`. Each target folder
gets a `LinuxStringTables` link to its tables, and git ignores both. Plural and device
variations become their `other` form. The script refuses substitutions.

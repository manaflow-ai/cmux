# CMUX fleet machine onboarding

Use this for a CMUX-controlled Mac or Linux machine that should become eligible for reviewed build, test, agent, cache, replay, or benchmark work.

The machine keeps its existing owners. SSH, MDM/configuration management, the CMUX build controller, GitHub Actions, and hosted runner providers continue to work independently. Enrollment records what the machine is allowed to do and proves each enabled role against current machine state.

Glaeda tracking: https://github.com/teamleaderleo/glaeda/issues/1056

## 1. Prepare the machine

Have an exact CMUX checkout and an exact Glaeda executable available locally. Package installation, accounts, SSH/Tailscale, MDM, and machine naming stay with the existing CMUX operator path.

For a Mac:

```bash
GLAEDA_ROOT=/absolute/path/to/glaeda
CMUX_ROOT=/absolute/path/to/cmux
CMUX_CACHE_ROOT=/absolute/path/to/cmux-native-cache
FLEET_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/glaeda/cmux-fleet"
GLAEDA_INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/glaeda/cmux-fleet"
GLAEDA_BIN="$GLAEDA_INSTALL_ROOT/glaeda"
umask 077
install -d -m 700 "$FLEET_ROOT" "$FLEET_ROOT/acceptance" "$GLAEDA_INSTALL_ROOT"

cd "$GLAEDA_ROOT"
./scripts/bootstrap
cargo build --locked --release --bin glaeda
if test -f "$GLAEDA_BIN" && ! test -e "$GLAEDA_INSTALL_ROOT/glaeda.rollback"; then
  cp -p "$GLAEDA_BIN" "$GLAEDA_INSTALL_ROOT/glaeda.rollback"
fi
install -m 755 target/release/glaeda "$GLAEDA_INSTALL_ROOT/.glaeda.next"
mv "$GLAEDA_INSTALL_ROOT/.glaeda.next" "$GLAEDA_BIN"

(
  cd "$CMUX_ROOT"
  ./scripts/setup.sh
)
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

bash scripts/cmux-fleet-bootstrap-macos \
  --cmux-root "$CMUX_ROOT" \
  --glaeda "$GLAEDA_BIN" \
  --cache-root "$CMUX_CACHE_ROOT" \
  --hardware-class cmux-mac-build-large \
  --role cmux_macos_native_build \
  > /tmp/cmux-fleet-bootstrap.json
```

For Linux:

```bash
GLAEDA_ROOT=/absolute/path/to/glaeda
CMUX_ROOT=/absolute/path/to/cmux
FLEET_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/glaeda/cmux-fleet"
GLAEDA_INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/glaeda/cmux-fleet"
GLAEDA_BIN="$GLAEDA_INSTALL_ROOT/glaeda"
umask 077
install -d -m 700 "$FLEET_ROOT" "$FLEET_ROOT/acceptance" "$GLAEDA_INSTALL_ROOT"

cd "$GLAEDA_ROOT"
./scripts/bootstrap
cargo build --locked --release --bin glaeda
if test -f "$GLAEDA_BIN" && ! test -e "$GLAEDA_INSTALL_ROOT/glaeda.rollback"; then
  cp -p "$GLAEDA_BIN" "$GLAEDA_INSTALL_ROOT/glaeda.rollback"
fi
install -m 755 target/release/glaeda "$GLAEDA_INSTALL_ROOT/.glaeda.next"
mv "$GLAEDA_INSTALL_ROOT/.glaeda.next" "$GLAEDA_BIN"

bash scripts/cmux-fleet-bootstrap-linux \
  --cmux-root "$CMUX_ROOT" \
  --glaeda "$GLAEDA_BIN" \
  --hardware-class cmux-linux-ci-medium \
  --role cmux_linux_ci \
  > /tmp/cmux-fleet-bootstrap.json
```

For native Mac build role, machine preparation reuses CMUX's reviewed `scripts/setup.sh`; bootstrap then re-observes the exact Xcode/SDK, Metal component, Zig compatibility, rustup/default Rust, pinned DiffSidecar Rust toolchain, submodules, setup artifacts, and clean canonical checkout. It also requires an existing operator-owned writable cache root with the configured disk headroom; its path stays local and never appears in the receipt. A bootstrap receipt with `eligibleForEnrollment: false` names the exact blocking checks. Repair those through the machine-management system that already owns them, then rerun bootstrap.

The commands above install or update the reviewed Glaeda binary in a stable per-user fleet location. A release package, MDM payload, or configuration manager can supply that exact path instead. The first update attempt preserves the previously installed binary as `glaeda.rollback`; later retries leave that copy untouched until the candidate generation is accepted. Before a new enrollment generation is accepted, rollback the candidate build with:

```bash
test -f "$GLAEDA_INSTALL_ROOT/glaeda.rollback"
mv "$GLAEDA_INSTALL_ROOT/glaeda.rollback" "$GLAEDA_BIN"
```

After successful re-enrollment and acceptance, remove the one-step rollback copy with `rm -f "$GLAEDA_INSTALL_ROOT/glaeda.rollback"`.

## 2. Create the enrollment record

Choose an opaque node ID. Hostnames, serial numbers, private addresses, usernames, and MDM identifiers stay out of the record.

```bash
cd "$GLAEDA_ROOT"
NODE_ID=cmux-mac-001 # use cmux-linux-001 for Linux

ENROLLMENT="$FLEET_ROOT/enrollment.json"
ENROLLMENT_NEXT="$(mktemp "$FLEET_ROOT/.enrollment.XXXXXX")"
python3 scripts/cmux_fleet.py enroll /tmp/cmux-fleet-bootstrap.json \
  --node-id "$NODE_ID" \
  --scope cmux-founders \
  --generation 1 \
  > "$ENROLLMENT_NEXT"
chmod 600 "$ENROLLMENT_NEXT"
mv "$ENROLLMENT_NEXT" "$ENROLLMENT"
```

The new record starts in `enrolling`. The canonical record lives at `$FLEET_ROOT/enrollment.json` with mode `0600`; finalized per-role acceptance receipts live under `$FLEET_ROOT/acceptance/`. These files survive reboot and contain no credentials.

## 3. Run the exact CMUX acceptance workload

The canonical CMUX checkout must be at the exact commit being accepted and clean.

Mac native build:

```bash
CMUX_COMMIT="$(git -C "$CMUX_ROOT" rev-parse HEAD)"
GLAEDA_GENERATION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["glaedaGeneration"])' "$ENROLLMENT")"
TOOLCHAIN_GENERATION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["supportedToolchainGenerations"][0])' "$ENROLLMENT")"
ENROLLMENT_GENERATION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["enrollmentGeneration"])' "$ENROLLMENT")"

bash "$CMUX_ROOT/scripts/fleet-accept-macos-native-build" \
  --commit "$CMUX_COMMIT" \
  --node-id "$NODE_ID" \
  --enrollment-generation "$ENROLLMENT_GENERATION" \
  --glaeda-generation "$GLAEDA_GENERATION" \
  --toolchain-generation "$TOOLCHAIN_GENERATION" \
  --output /tmp/cmux-fleet-acceptance-evidence.json
```

Linux CI:

```bash
CMUX_COMMIT="$(git -C "$CMUX_ROOT" rev-parse HEAD)"
GLAEDA_GENERATION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["glaedaGeneration"])' "$ENROLLMENT")"
TOOLCHAIN_GENERATION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["supportedToolchainGenerations"][0])' "$ENROLLMENT")"
ENROLLMENT_GENERATION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["enrollmentGeneration"])' "$ENROLLMENT")"

bash "$CMUX_ROOT/scripts/fleet-accept-linux-ci" \
  --commit "$CMUX_COMMIT" \
  --node-id "$NODE_ID" \
  --enrollment-generation "$ENROLLMENT_GENERATION" \
  --glaeda-generation "$GLAEDA_GENERATION" \
  --toolchain-generation "$TOOLCHAIN_GENERATION" \
  --output /tmp/cmux-fleet-acceptance-evidence.json
```

The Mac recipe uses a fresh private DerivedData directory, performs a clean Debug build, verifies the `cmux DEV` executable, and checks process settlement. The Linux recipe materializes the exact commit into a private temporary tree and runs the self-hosted-runner guard plus Linux routing unittest there.

## 4. Finalize acceptance

```bash
cd "$GLAEDA_ROOT"

case "$(uname -s)" in
  Darwin) ACCEPTANCE_ROLE=cmux_macos_native_build ;;
  Linux) ACCEPTANCE_ROLE=cmux_linux_ci ;;
  *) echo "unsupported host" >&2; exit 1 ;;
esac

ACCEPTANCE="$FLEET_ROOT/acceptance/$ACCEPTANCE_ROLE.json"
ACCEPTANCE_NEXT="$(mktemp "$FLEET_ROOT/acceptance/.$ACCEPTANCE_ROLE.XXXXXX")"
python3 scripts/cmux_fleet.py finalize-acceptance \
  "$ENROLLMENT" \
  /tmp/cmux-fleet-acceptance-evidence.json \
  > "$ACCEPTANCE_NEXT"
chmod 600 "$ACCEPTANCE_NEXT"
mv "$ACCEPTANCE_NEXT" "$ACCEPTANCE"
```

The receipt must say `result: accepted`.

## 5. Mark the node eligible and verify fleet-visible state

```bash
python3 scripts/cmux_fleet.py transition-apply \
  "$ENROLLMENT" --to eligible \
  --acceptance "$ACCEPTANCE"

bash scripts/cmux-fleet status "$ENROLLMENT" \
  --acceptance "$ACCEPTANCE"
```

The supported transition into `eligible` requires a current accepted role receipt. Glaeda's `transition` command remains a read-only planner; the documented `transition-apply` path serializes participating mutations under one private lock, rechecks current state, fsyncs a mode-0600 same-directory stage, atomically replaces `enrollment.json`, fsyncs the fleet directory, and revalidates the published bytes. Treat role eligibility only as routing-candidate evidence; current host pressure/admission and the higher-level routing policy still decide whether work is selected. Enrollment presence or hostname matching never grants a role.

This onboarding path does not register a GitHub runner, change repository runner variables, alter the CMUX controller, or replace direct SSH. CI runner routing stays governed by [ci-runners.md](ci-runners.md) and the relevant RFCs.

Remove the transient bootstrap and acceptance-evidence files after the canonical records are installed:

```bash
rm -f /tmp/cmux-fleet-bootstrap.json /tmp/cmux-fleet-acceptance-evidence.json
```

## 6. Drain, quarantine, recover, or retire

Before planned operator work:

```bash
python3 "$GLAEDA_ROOT/scripts/cmux_fleet.py" transition-apply \
  "$ENROLLMENT" --to draining
```

Rollback that hold after the machine is unchanged and its current acceptance still applies:

```bash
python3 "$GLAEDA_ROOT/scripts/cmux_fleet.py" transition-apply \
  "$ENROLLMENT" --to eligible \
  --acceptance "$ACCEPTANCE"
```

Quarantine a concrete mismatch:

```bash
python3 "$GLAEDA_ROOT/scripts/cmux_fleet.py" transition-apply \
  "$ENROLLMENT" \
  --to quarantined --reason toolchain_mismatch
```

After an OS, toolchain, hardware class, Glaeda update, or reviewed role-acceptance workload change, rerun bootstrap and create enrollment generation N+1, then rerun acceptance. The role acceptance workload generation is the SHA-256 of the exact CMUX `scripts/fleet_acceptance.py` bytes and must match the acceptance receipt. Old receipts become stale automatically. Leaving quarantine also advances the generation before fresh acceptance.

Retire or roll back an onboarding before routing:

```bash
python3 "$GLAEDA_ROOT/scripts/cmux_fleet.py" transition-apply \
  "$ENROLLMENT" --to retired

bash "$GLAEDA_ROOT/scripts/cmux-fleet" status "$ENROLLMENT"
```

The retired record is a local tombstone with zero routable roles.

## Current physical acceptance status

The Mac and Linux recipes are repository-owned and fixture-tested. First physical receipts wait for explicitly provisioned CMUX hardware.

Related CMUX work: #13091, #13095, #13198, #13325.
Related Glaeda work: teamleaderleo/glaeda#743, #546, #365, #492, #970, #1048, #1008, #1010, #1056.

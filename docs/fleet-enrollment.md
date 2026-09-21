# CMUX fleet machine onboarding

Use this path for CMUX-controlled Mac or Linux hardware that should be eligible for reviewed repository-owned work while existing owners keep their responsibilities.

SSH, MDM/configuration management, the CMUX controller, GitHub Actions, hosted runners, and direct operator access remain separate coordination systems. CMUX defines what a semantic workload means. Glaeda records whether the machine is enrolled for that role and whether a current exact acceptance result exists.

Glaeda tracking: teamleaderleo/glaeda#1056 and #1057.

## Contract boundary

The first reviewed role bindings are:

| Fleet role | CMUX workload profile |
| --- | --- |
| `cmux_macos_native_build` | `cmux.macos.dev-check@1` |
| `cmux_linux_ci` | `cmux.ci.guard@1` |

The profile registry in `scripts/ci/cmux-workload-profiles.json` owns repository entrypoint, semantic validator, reviewed environment class, expected result class, timeout, resource class, network class, benchmark state classes, runtime inputs, and artifact classes. Profile children receive a closed environment; arbitrary caller PATH, SSH agents, tokens, and unrelated CI variables do not flow into the workload.

Glaeda consumes that profile identity and the canonical `cmux-workload-result/v1` emitted by `scripts/ci/cmux_workload_profile.py`. Glaeda does not maintain another list of CMUX commands or another CMUX pass/fail definition.

Role enrollment is routing-candidate evidence only. Glaeda still performs fresh local admission before execution, and higher-level routing policy still decides whether an eligible node should receive work.

## 1. Prepare the machine

Have exact CMUX and Glaeda checkouts locally. Package installation, accounts, SSH/Tailscale, MDM, power policy, and machine naming stay with the existing operator path.

Common variables:

```bash
set -euo pipefail
GLAEDA_ROOT=/absolute/path/to/glaeda
CMUX_ROOT=/absolute/path/to/cmux
FLEET_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/glaeda/cmux-fleet"
GLAEDA_INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/glaeda/cmux-fleet"
GLAEDA_BIN="$GLAEDA_INSTALL_ROOT/glaeda"
umask 077
install -d -m 700 "$FLEET_ROOT" "$FLEET_ROOT/acceptance" "$GLAEDA_INSTALL_ROOT"
BOOTSTRAP="$(mktemp "$FLEET_ROOT/.bootstrap.XXXXXX")"
chmod 600 "$BOOTSTRAP"

cd "$GLAEDA_ROOT"
./scripts/bootstrap
cargo build --locked --release --bin glaeda
if test -f "$GLAEDA_BIN" && ! test -e "$GLAEDA_INSTALL_ROOT/glaeda.rollback"; then
  cp -p "$GLAEDA_BIN" "$GLAEDA_INSTALL_ROOT/glaeda.rollback"
fi
install -m 755 target/release/glaeda "$GLAEDA_INSTALL_ROOT/.glaeda.next"
mv "$GLAEDA_INSTALL_ROOT/.glaeda.next" "$GLAEDA_BIN"
```

The first candidate install preserves the previously installed Glaeda binary as `glaeda.rollback`. Repeated candidate installs leave that copy untouched until the new enrollment is accepted.

For a Mac native-build node, prepare CMUX's normal build prerequisites and choose the operator-owned cache root:

```bash
CMUX_CACHE_ROOT=/absolute/path/to/cmux-native-cache
(
  cd "$CMUX_ROOT"
  ./scripts/setup.sh
)
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

bash "$GLAEDA_ROOT/scripts/cmux-fleet-bootstrap-macos" \
  --cmux-root "$CMUX_ROOT" \
  --glaeda "$GLAEDA_BIN" \
  --cache-root "$CMUX_CACHE_ROOT" \
  --hardware-class cmux-mac-build-large \
  --role cmux_macos_native_build \
  > "$BOOTSTRAP"
```

For a Linux CI node:

```bash
bash "$GLAEDA_ROOT/scripts/cmux-fleet-bootstrap-linux" \
  --cmux-root "$CMUX_ROOT" \
  --glaeda "$GLAEDA_BIN" \
  --hardware-class cmux-linux-ci-medium \
  --role cmux_linux_ci \
  > "$BOOTSTRAP"
```

Bootstrap is read-only. It verifies the exact CMUX checkout exposes the reviewed role profile at generation 1 and that the observed OS/architecture can run it.

## 2. Create the enrollment record

Choose an opaque node ID. Hostnames, serial numbers, private addresses, usernames, and MDM identifiers stay out of the record.

```bash
set -euo pipefail
cd "$GLAEDA_ROOT"
case "$(uname -s)" in
  Darwin) NODE_ID=cmux-mac-001 ;;
  Linux) NODE_ID=cmux-linux-001 ;;
  *) echo "unsupported host" >&2; exit 1 ;;
esac

ENROLLMENT="$FLEET_ROOT/enrollment.json"
ENROLLMENT_NEXT="$(mktemp "$FLEET_ROOT/.enrollment.XXXXXX")"
python3 scripts/cmux_fleet.py enroll "$BOOTSTRAP" \
  --node-id "$NODE_ID" \
  --scope cmux-founders \
  --generation 1 \
  > "$ENROLLMENT_NEXT"
chmod 600 "$ENROLLMENT_NEXT"
mv "$ENROLLMENT_NEXT" "$ENROLLMENT"
```

The new enrollment starts in `enrolling`. It records the role's exact CMUX profile ID/generation, the observed toolchain generation, the installed Glaeda generation, and bounded machine capability classes.

## 3. Fleet eligibility activation gate

The repository-owned workload profiles in this change are usable independently of hardware eligibility. Stop after the enrollment record for now.

Glaeda #1088 added the reviewed local-attempt/v2 acceptance contract, and teamleaderleo/glaeda#1091 is repairing its child-process environment boundary. Until #1091 is merged into Glaeda `main`:

- do not transition a CMUX fleet enrollment to `eligible` using this document;
- do not treat a standalone `cmux-workload-result/v1` as machine acceptance;
- keep existing hosted/dev-fleet routing policy unchanged;
- use the profile runner for semantic CI/dev execution and benchmark comparison only.

The activation follow-up will restore the exact `accept-local` operator flow after its execution-safety repair is accepted. CMUX continues to own workload commands, validators, artifacts, environment class, timeout, and semantic terminal result. Glaeda owns the local attempt, post-run machine re-observation, durable acceptance receipt, lifecycle, and fresh local admission.

Delaying activation costs fleet availability only. It leaves the canonical CMUX workload semantics introduced here usable and independently reviewable.

## CI and physical proof

Hosted CI validates the CMUX profile contract and Glaeda's enrollment/result-binding contract without claiming physical hardware acceptance.

The first physical proof should use one CMUX-owned host with two caller classes converging on the same machine-local lease boundary. The preferred proof remains a GitHub Actions compile request plus a direct CMUX native request, or the Linux equivalent.

Related CMUX work: #13091, #13095, #13198, #13325, #13411.
Related Glaeda work: teamleaderleo/glaeda#546, #970, #1010, #1056, #1057, #1071, #1088, #1091.

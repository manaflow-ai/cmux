#!/usr/bin/env bash
# Guards the cross-language `devices` sync-collection payload contract.
#
# Enforces (see plans/feat-ios-device-list-v2/PLAN.md Stage 1):
#   1. The golden fixtures + the field-set lock + _expected.json all exist.
#   2. Coverage: every field in the lock appears in >=1 fixture (the contract is
#      exercised), and every DeviceRecord/DeviceInstanceRecord-level field present
#      in the fixtures is declared in the lock (a new field must be added to the
#      lock on purpose).
#   3. Additive-only: versus the PR base ref, no field is removed, renamed, or
#      retyped in the lock. Additions ARE allowed and do NOT bump schemaVersion
#      (per the substrate, workers/presence/src/sync.ts: "Additive payload fields
#      do NOT bump this"; the additive-only check here is itself the compat
#      guarantee). Route-internal keys (CmxAttachRoute) and the deliberate
#      `future*` forward-compat probe keys are out of scope.
#   4. The lock's `schemaVersion` tracks the substrate constants: it must equal
#      SYNC_SCHEMA_VERSION (worker) and syncSchemaVersion (Swift), so the lock
#      cannot claim a wire-schema version that diverges from the real code.
#
# Usage: scripts/lint-sync-contract.sh [base-ref]   (default base: origin/main)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BASE_REF="${1:-${SYNC_CONTRACT_BASE:-origin/main}}"
LOCK_REL="Packages/Shared/CmuxSyncStore/Fixtures/devices/device-record.fields.json"
FIX_DIR="${REPO_ROOT}/Packages/Shared/CmuxSyncStore/Fixtures/devices"

# Best-effort base lock (empty when the file is new on this branch).
BASE_LOCK=""
if git -C "$REPO_ROOT" cat-file -e "${BASE_REF}:${LOCK_REL}" 2>/dev/null; then
  BASE_LOCK="$(git -C "$REPO_ROOT" show "${BASE_REF}:${LOCK_REL}")"
fi

# Substrate schema-version constants (the lock must track these).
WORKER_SV="$(grep -oE 'SYNC_SCHEMA_VERSION *= *[0-9]+' "$REPO_ROOT/workers/presence/src/sync.ts" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
SWIFT_SV="$(grep -oE 'syncSchemaVersion *= *[0-9]+' "$REPO_ROOT/Packages/Shared/CmuxSyncStore/Sources/CmuxSyncStore/SyncProtocol.swift" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"

FIX_DIR="$FIX_DIR" BASE_LOCK="$BASE_LOCK" WORKER_SV="$WORKER_SV" SWIFT_SV="$SWIFT_SV" python3 - <<'PY'
import json, os, sys, glob

fix_dir = os.environ["FIX_DIR"]
errs = []

def load(path):
    with open(path) as f:
        return json.load(f)

lock_path = os.path.join(fix_dir, "device-record.fields.json")
exp_path = os.path.join(fix_dir, "_expected.json")
for required in (lock_path, exp_path):
    if not os.path.exists(required):
        print(f"lint-sync-contract: missing required file {required}", file=sys.stderr)
        sys.exit(1)

lock = load(lock_path)
types = lock.get("types", {})
record_fields = set(types.get("DeviceRecord", {}))
instance_fields = set(types.get("DeviceInstanceRecord", {}))

fixtures = [p for p in glob.glob(os.path.join(fix_dir, "*.json"))
            if os.path.basename(p) not in ("device-record.fields.json", "_expected.json")]
if len(fixtures) < 5:
    errs.append(f"expected >=5 fixtures, found {len(fixtures)}")

def is_probe(k):  # deliberate forward-compat unknown keys
    return k.startswith("future")

seen_record, seen_instance = set(), set()
per_fixture = []  # (name, record_keys, [instance_keys, ...]) for decodable fixtures
for p in fixtures:
    obj = load(p)
    if not isinstance(obj, dict) or not obj:  # tombstone {} carries no fields
        continue
    rkeys = {k for k in obj if not is_probe(k)}
    ikeys_list = []
    for inst in obj.get("instances", []):
        if isinstance(inst, dict):
            ik = {k for k in inst if not is_probe(k)}
            ikeys_list.append(ik)
            seen_instance |= ik
    seen_record |= rkeys
    per_fixture.append((os.path.basename(p), rkeys, ikeys_list))

# Reverse coverage: a fixture field must be declared in the lock (add it on purpose).
for k in sorted(seen_record - record_fields):
    errs.append(f"DeviceRecord field '{k}' is in a fixture but not in the lock; add it to device-record.fields.json")
for k in sorted(seen_instance - instance_fields):
    errs.append(f"DeviceInstanceRecord field '{k}' is in a fixture but not in the lock; add it to device-record.fields.json")
# Forward coverage: a locked field must be exercised by a fixture.
for k in sorted(record_fields - seen_record):
    errs.append(f"DeviceRecord field '{k}' is locked but no fixture exercises it; add/extend a fixture")
for k in sorted(instance_fields - seen_instance):
    errs.append(f"DeviceInstanceRecord field '{k}' is locked but no fixture exercises it; add/extend a fixture")

# Optional fields (lock type ends with "?") must be ABSENT in >=1 decodable
# fixture, so an optional->required change (a real compat break) is caught.
def optional_fields(tdef):
    return [f for f, t in tdef.items() if isinstance(t, str) and t.endswith("?")]
for f in optional_fields(types.get("DeviceRecord", {})):
    if not any(f not in rkeys for _, rkeys, _ in per_fixture):
        errs.append(f"optional DeviceRecord field '{f}' is present in EVERY fixture; add a decodable fixture that omits it so optional->required is caught")
for f in optional_fields(types.get("DeviceInstanceRecord", {})):
    if not any(any(f not in ik for ik in iks) for _, _, iks in per_fixture if iks):
        errs.append(f"optional DeviceInstanceRecord field '{f}' is present in EVERY instance; add a fixture instance that omits it")

# Additive-only vs base.
base_raw = os.environ.get("BASE_LOCK", "")
if base_raw.strip():
    base = json.loads(base_raw)
    base_types = base.get("types", {})
    for tname, bfields in base_types.items():
        cfields = types.get(tname)
        if cfields is None:
            errs.append(f"type '{tname}' was removed from the lock (non-additive)")
            continue
        for fname, btype in bfields.items():
            if fname not in cfields:
                errs.append(f"{tname}.{fname} was removed/renamed in the lock (non-additive); wire fields are append-only")
            elif cfields[fname] != btype:
                errs.append(f"{tname}.{fname} changed type '{btype}' -> '{cfields[fname]}' (non-additive); add a new field instead")

# The lock's schemaVersion must track the substrate constants (Swift + worker),
# so the lock cannot claim a wire-schema version that diverges from the code.
lock_sv = lock.get("schemaVersion")
if lock_sv is None:
    errs.append("lock is missing required 'schemaVersion'")
# Hard-fail (never fail open): if a source constant cannot be read, the guard is
# no longer checking a real source of truth, so treat it as a failure rather than
# silently skipping that side.
for label, raw in (("worker SYNC_SCHEMA_VERSION", os.environ.get("WORKER_SV", "")),
                   ("Swift syncSchemaVersion", os.environ.get("SWIFT_SV", ""))):
    raw = raw.strip()
    if not raw:
        errs.append(f"could not read {label} from source; the schema-version guard must not fail open. If the constant moved/renamed, update scripts/lint-sync-contract.sh")
    elif lock_sv is not None and int(raw) != int(lock_sv):
        errs.append(f"lock schemaVersion {lock_sv} != {label} {raw}; keep the lock in lockstep with the substrate constants")

if errs:
    print("lint-sync-contract: FAIL", file=sys.stderr)
    for e in errs:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print(f"lint-sync-contract: OK ({len(fixtures)} fixtures, "
      f"{len(record_fields)} DeviceRecord + {len(instance_fields)} DeviceInstanceRecord fields locked)")
PY

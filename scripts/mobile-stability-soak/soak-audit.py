#!/usr/bin/env python3
import json
import os
import time
from pathlib import Path


INTERVAL_SECONDS = float(os.environ.get("SOAK_AUDIT_INTERVAL_SECONDS", "300"))
STATUS_OUT = Path(os.environ.get("SOAK_AUDIT_STATUS", "/tmp/cmux-mobile-soak/audit.json"))
REQUIRED_SECONDS = int(os.environ.get("SOAK_SECONDS", "43200"))
STALE_SECONDS = float(os.environ.get("SOAK_STALE_SECONDS", "300"))
PATHS = {
    "iphone": Path(os.environ["IPHONE_STATUS"]),
    "ipad": Path(os.environ["IPAD_STATUS"]),
    "mac": Path(os.environ["MAC_STATUS"]),
    "resources": Path(os.environ["RESOURCE_STATUS"]),
}


def load_status(path: Path) -> dict[str, object]:
    if not path.exists():
        return {"status": "missing", "failures": 1, "elapsed_seconds": 0}
    try:
        data = json.loads(path.read_text())
    except Exception as exc:
        return {"status": "invalid", "failures": 1, "elapsed_seconds": 0, "error": str(exc)}
    age = time.time() - path.stat().st_mtime
    data["status_file_age_seconds"] = round(age, 1)
    if data.get("status") == "running" and age > STALE_SECONDS:
        data["status"] = "failed"
        data["failures"] = max(1, int(data.get("failures", 0)))
        data["error"] = f"status stale for {age:.1f}s"
    return data


def write_audit() -> dict[str, object]:
    checks = {name: load_status(path) for name, path in PATHS.items()}
    terminal_checks = {name: checks[name] for name in ("iphone", "ipad", "mac")}
    all_passed = all(item.get("status") == "passed" for item in checks.values())
    no_failures = all(int(item.get("failures", 1)) == 0 for item in checks.values())
    long_enough = all(float(item.get("elapsed_seconds", 0)) >= REQUIRED_SECONDS for item in terminal_checks.values())
    resource_long_enough = float(checks["resources"].get("elapsed_seconds", 0)) >= REQUIRED_SECONDS
    completed_with_failures = all_passed and not no_failures
    failed = any(item.get("status") == "failed" for item in checks.values()) or completed_with_failures
    achieved = all_passed and no_failures and long_enough and resource_long_enough

    payload = {
        "achieved": achieved,
        "status": "passed" if achieved else ("failed" if failed else "running"),
        "required_seconds": REQUIRED_SECONDS,
        "checks": checks,
    }
    STATUS_OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATUS_OUT.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    tmp.replace(STATUS_OUT)
    print(json.dumps({
        "status": payload["status"],
        "achieved": achieved,
        "iphone": checks["iphone"].get("status"),
        "ipad": checks["ipad"].get("status"),
        "mac": checks["mac"].get("status"),
        "resources": checks["resources"].get("status"),
    }), flush=True)
    return payload


def main() -> int:
    while True:
        payload = write_audit()
        if payload["status"] == "passed":
            return 0
        if payload["status"] == "failed":
            return 1
        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    raise SystemExit(main())

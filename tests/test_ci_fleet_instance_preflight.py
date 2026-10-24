#!/usr/bin/env python3
"""Behavioral checks for the GCE instance permission preflight."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/fleet-instance-preflight.sh"


class FleetInstancePreflightTests(unittest.TestCase):
    def run_case(self, gcloud_body: str, *, gcloud_exit: int = 0,
                 metadata: bool = True, explicit: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp:
            bin_dir = Path(temp) / "bin"
            bin_dir.mkdir()
            curl = "#!/bin/sh\n"
            if metadata:
                curl += (
                    "case \"$*\" in\n"
                    "  *instance/name*) echo selected-instance ;;\n"
                    "  *instance/zone*) echo us-west1-a ;;\n"
                    "  *project/project-id*) echo test-project ;;\n"
                    "esac\n"
                )
            (bin_dir / "curl").write_text(curl)
            calls = Path(temp) / "gcloud.args"
            (bin_dir / "gcloud").write_text(
                "#!/bin/sh\n"
                f"printf 'ARGS:%s\\n' \"$*\" > {calls}\n"
                f"cat >&2 <<'EOF'\n{gcloud_body}\nEOF\n"
                f"exit {gcloud_exit}\n"
            )
            for path in (bin_dir / "curl", bin_dir / "gcloud"):
                path.chmod(0o755)
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", RUNNER_TEMP=temp,
                       **(explicit or {}))
            result = subprocess.run(["bash", str(SCRIPT)], env=env, text=True,
                                    capture_output=True, check=False)
            result.gcloud_args = calls.read_text() if calls.exists() else ""
            return result

    def test_permission_denial_is_reported_before_dispatch(self) -> None:
        result = self.run_case("Required 'compute.instances.get' permission for selected instance", gcloud_exit=1)
        self.assertEqual(result.returncode, 69)
        self.assertIn("compute.instances.get", result.stdout)
        self.assertIn("No CI job was dispatched", result.stdout)
        self.assertIn("grant the permission", result.stdout)

    def test_other_cloud_failure_is_not_mislabeled_as_iam(self) -> None:
        result = self.run_case("connection refused", gcloud_exit=1)
        self.assertEqual(result.returncode, 69)
        self.assertIn("Fleet instance preflight failed", result.stdout)
        self.assertNotIn("compute.instances.get", result.stdout)

    def test_success_allows_dispatch(self) -> None:
        result = self.run_case("", gcloud_exit=0)
        self.assertEqual(result.returncode, 0)

    def test_describe_receives_the_instance_location(self) -> None:
        # Explicit targets exercise the path used when a caller already knows
        # the selected instance rather than relying on metadata.
        result = self.run_case("", explicit={
            "CMUX_CI_FLEET_INSTANCE": "selected-instance",
            "CMUX_CI_FLEET_ZONE": "us-west1-a",
            "CMUX_CI_FLEET_PROJECT": "test-project",
        })
        self.assertEqual(result.returncode, 0)
        self.assertIn("ARGS:compute instances describe selected-instance --zone us-west1-a --project test-project", result.gcloud_args)

    def test_non_gce_runner_skips_cloud_probe(self) -> None:
        result = self.run_case("should not be reached", gcloud_exit=1, metadata=False)
        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()

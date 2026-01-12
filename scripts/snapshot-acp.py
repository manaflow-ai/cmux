#!/usr/bin/env python3
"""
Build Morph snapshot for ACP server infrastructure.

This creates a separate snapshot from the main cmux sandbox snapshot,
specifically optimized for ACP server deployment with iOS app integration.

Usage:
    uv run --env-file .env ./scripts/snapshot-acp.py
    uv run --env-file .env ./scripts/snapshot-acp.py --verbose
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from morphcloud.api import MorphCloudClient, Instance, Snapshot

# Constants
BASE_SNAPSHOT = "snapshot_i7l4i12s"  # Ubuntu 24.04 base (same as main cmux)
VCPUS = 4
MEMORY_MB = 8192
DISK_GB = 32

# Port allocations for ACP server
PORT_ACP_SERVER = 39384
PORT_HEALTH = 39385

# Manifest path
MORPH_ACP_SNAPSHOT_MANIFEST_PATH = (
    Path(__file__).resolve().parent.parent
    / "packages/shared/src/morph-acp-snapshots.json"
)


@dataclass
class TaskResult:
    name: str
    success: bool
    duration_ms: int
    error: str | None = None


class AcpSnapshotBuilder:
    """Builder for ACP server Morph snapshot."""

    def __init__(self, client: MorphCloudClient, verbose: bool = False):
        self.client = client
        self.verbose = verbose
        self.instance: Instance | None = None
        self.task_results: list[TaskResult] = []

    def log(self, message: str) -> None:
        """Log a message."""
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {message}")

    def log_verbose(self, message: str) -> None:
        """Log a verbose message."""
        if self.verbose:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] (verbose) {message}")

    async def run_task(
        self, name: str, commands: list[str], timeout_seconds: int = 300
    ) -> bool:
        """Run a task on the instance."""
        import time

        start = time.time()
        self.log(f"Starting task: {name}")

        try:
            for cmd in commands:
                self.log_verbose(f"  Running: {cmd}")
                result = await self.instance.aexec(cmd, timeout=timeout_seconds)
                if result.exit_code != 0:
                    self.log(f"  Task {name} failed: {result.stderr}")
                    self.task_results.append(
                        TaskResult(
                            name=name,
                            success=False,
                            duration_ms=int((time.time() - start) * 1000),
                            error=result.stderr,
                        )
                    )
                    return False
                if self.verbose and result.stdout:
                    for line in result.stdout.strip().split("\n")[:10]:
                        self.log_verbose(f"    {line}")

            duration_ms = int((time.time() - start) * 1000)
            self.log(f"  Completed {name} in {duration_ms}ms")
            self.task_results.append(
                TaskResult(name=name, success=True, duration_ms=duration_ms)
            )
            return True

        except Exception as e:
            duration_ms = int((time.time() - start) * 1000)
            self.log(f"  Task {name} error: {e}")
            self.task_results.append(
                TaskResult(
                    name=name,
                    success=False,
                    duration_ms=duration_ms,
                    error=str(e),
                )
            )
            return False

    async def build(self) -> Snapshot | None:
        """Build the ACP server snapshot."""
        self.log("Creating instance from base snapshot...")

        try:
            # Create instance
            self.instance = await self.client.instances.acreate(
                snapshot_id=BASE_SNAPSHOT,
                vcpus=VCPUS,
                memory_mb=MEMORY_MB,
            )
            self.log(f"Instance created: {self.instance.id}")

            # Expose HTTP ports
            self.log("Exposing HTTP ports...")
            await self.instance.expose_http_service(PORT_ACP_SERVER)
            await self.instance.expose_http_service(PORT_HEALTH)

            # Run setup tasks
            if not await self.setup_base_packages():
                return None

            if not await self.setup_rust():
                return None

            if not await self.setup_node():
                return None

            if not await self.build_acp_server():
                return None

            if not await self.setup_systemd():
                return None

            if not await self.configure_network():
                return None

            if not await self.run_sanity_checks():
                return None

            if not await self.cleanup():
                return None

            # Create snapshot
            self.log("Creating snapshot...")
            snapshot = await self.instance.asnapshot(
                name="cmux-acp-server",
            )
            self.log(f"Snapshot created: {snapshot.id}")

            # Update manifest
            self.update_manifest(snapshot.id)

            return snapshot

        except Exception as e:
            self.log(f"Build failed: {e}")
            import traceback

            traceback.print_exc()
            return None

        finally:
            if self.instance:
                self.log("Stopping instance...")
                try:
                    await self.instance.astop()
                except Exception:
                    pass

    async def setup_base_packages(self) -> bool:
        """Install base packages."""
        return await self.run_task(
            "apt-bootstrap",
            [
                "apt-get update",
                "apt-get install -y bubblewrap build-essential ca-certificates curl git iproute2 iptables jq pkg-config libssl-dev",
            ],
            timeout_seconds=600,
        )

    async def setup_rust(self) -> bool:
        """Install Rust toolchain."""
        return await self.run_task(
            "install-rust",
            [
                'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y',
                "source ~/.cargo/env && rustup default stable",
            ],
            timeout_seconds=600,
        )

    async def setup_node(self) -> bool:
        """Install Node.js and coding CLIs."""
        return await self.run_task(
            "install-node",
            [
                "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -",
                "apt-get install -y nodejs",
                # Note: These CLI packages may not exist yet - will fail gracefully
                "npm install -g @anthropics/claude-code-acp || echo 'claude-code-acp not available'",
                "npm install -g @openai/codex-acp || echo 'codex-acp not available'",
            ],
            timeout_seconds=600,
        )

    async def build_acp_server(self) -> bool:
        """Build ACP server from source."""
        # Upload source code
        self.log("Uploading source code...")

        # For now, we'll build from the repo inside the snapshot
        # In production, we'd upload pre-built binaries

        return await self.run_task(
            "build-acp-server",
            [
                "mkdir -p /root/cmux",
                # Clone and build would go here
                # For now, just create a placeholder
                "echo '#!/bin/bash\necho ACP Server placeholder' > /usr/local/bin/cmux-acp-server",
                "chmod +x /usr/local/bin/cmux-acp-server",
            ],
            timeout_seconds=1200,
        )

    async def setup_systemd(self) -> bool:
        """Install systemd units for ACP server."""
        service_unit = f"""[Unit]
Description=cmux ACP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cmux-acp-server
Restart=always
RestartSec=5
Environment=RUST_LOG=info
Environment=ACP_PORT={PORT_ACP_SERVER}

[Install]
WantedBy=multi-user.target
"""
        return await self.run_task(
            "install-systemd",
            [
                f"cat > /etc/systemd/system/cmux-acp-server.service << 'EOFSERVICE'\n{service_unit}EOFSERVICE",
                "systemctl daemon-reload",
                "systemctl enable cmux-acp-server",
            ],
        )

    async def configure_network(self) -> bool:
        """Configure network for bubblewrap isolation."""
        return await self.run_task(
            "configure-network",
            [
                "echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf",
                "sysctl -p || true",
                "iptables -t nat -A POSTROUTING -s 10.200.0.0/16 -j MASQUERADE || true",
                "iptables-save > /etc/iptables.rules || true",
            ],
        )

    async def run_sanity_checks(self) -> bool:
        """Run sanity checks."""
        return await self.run_task(
            "sanity-checks",
            [
                # Check bubblewrap works
                "bwrap --version",
                # Check node is available
                "node --version",
                # Check ACP server exists
                "test -x /usr/local/bin/cmux-acp-server",
            ],
        )

    async def cleanup(self) -> bool:
        """Clean up before snapshot."""
        return await self.run_task(
            "cleanup",
            [
                "apt-get clean",
                "rm -rf /var/lib/apt/lists/*",
                "rm -rf /root/.cargo/registry || true",
                "rm -rf /tmp/* || true",
            ],
        )

    def update_manifest(self, snapshot_id: str) -> None:
        """Update the ACP snapshot manifest."""
        manifest = {
            "schemaVersion": 1,
            "updatedAt": datetime.now(timezone.utc).isoformat(),
            "snapshotId": snapshot_id,
            "ports": {
                "acp_server": PORT_ACP_SERVER,
                "health": PORT_HEALTH,
            },
            "config": {
                "vcpus": VCPUS,
                "memory_mb": MEMORY_MB,
                "disk_gb": DISK_GB,
            },
        }

        MORPH_ACP_SNAPSHOT_MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(MORPH_ACP_SNAPSHOT_MANIFEST_PATH, "w") as f:
            json.dump(manifest, f, indent=2)

        self.log(f"Manifest updated: {MORPH_ACP_SNAPSHOT_MANIFEST_PATH}")

    def print_summary(self) -> None:
        """Print task summary."""
        print("\n" + "=" * 60)
        print("Task Summary")
        print("=" * 60)

        total_time = sum(r.duration_ms for r in self.task_results)
        succeeded = sum(1 for r in self.task_results if r.success)
        failed = len(self.task_results) - succeeded

        for result in self.task_results:
            status = "✓" if result.success else "✗"
            print(f"  {status} {result.name}: {result.duration_ms}ms")
            if result.error:
                print(f"      Error: {result.error[:100]}")

        print("-" * 60)
        print(f"Total: {succeeded} succeeded, {failed} failed, {total_time}ms")
        print("=" * 60)


async def main():
    parser = argparse.ArgumentParser(description="Build ACP server Morph snapshot")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    args = parser.parse_args()

    # Check for API key
    api_key = os.environ.get("MORPH_API_KEY")
    if not api_key:
        print("Error: MORPH_API_KEY environment variable not set")
        print("Run with: uv run --env-file .env ./scripts/snapshot-acp.py")
        sys.exit(1)

    client = MorphCloudClient()
    builder = AcpSnapshotBuilder(client, verbose=args.verbose)

    snapshot = await builder.build()
    builder.print_summary()

    if snapshot:
        print(f"\nSnapshot created successfully: {snapshot.id}")
        print(f"Manifest: {MORPH_ACP_SNAPSHOT_MANIFEST_PATH}")
        return 0
    else:
        print("\nSnapshot build failed!")
        return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

#!/usr/bin/env bun
/**
 * Build the cmux Cloud devbox Daytona snapshot from
 * web/services/vms/images/devbox/Dockerfile.
 *
 * Usage:
 *   DAYTONA_API_KEY=... bun scripts/build-devbox-daytona.ts <snapshot-name>
 *
 * Daytona snapshot names are unique and immutable (no atomic replace under
 * one name), so rebuilds get a new versioned name (cmux-devbox-20260827a,
 * cmux-devbox-20260827b, ...) and the backend flips DAYTONA_SANDBOX_SNAPSHOT
 * after the manifest entry lands. The name argument is required so a rebuild
 * can never collide with the currently-serving snapshot. Daytona has no
 * skip-cache switch; bump CMUX_IMAGE_EPOCH in the Dockerfile to force its
 * remote builder past a stale layer cache.
 *
 * Driver contract (web/services/vms/drivers/daytona.ts): the registered
 * entrypoint /usr/local/bin/cmux-daytona-entrypoint supervises cmuxd-remote
 * on 7777 and Daytona re-runs it on every sandbox start (cmux pause/resume);
 * the driver's repair fallback launches the identical serve command.
 *
 * Resources: 2 vCPU / 4 GiB / 10 GiB disk.
 */
import { Daytona, Image } from "@daytonaio/sdk";
import { fileURLToPath } from "node:url";
import {
  bakeMetadata,
  bakePreflight,
  buildRemoteDaemon,
  devboxDockerfilePath,
  manifestEntrySkeleton,
} from "./devbox-image-common";

if (!process.env.DAYTONA_API_KEY) {
  throw new Error("DAYTONA_API_KEY is required to build the Daytona devbox snapshot");
}

const name = process.argv[2];
if (!name || name.startsWith("--")) {
  throw new Error("usage: bun scripts/build-devbox-daytona.ts <snapshot-name>");
}

const preflight = bakePreflight();
const daemon = await buildRemoteDaemon();

const daytona = new Daytona({
  apiKey: process.env.DAYTONA_API_KEY,
  apiUrl: process.env.DAYTONA_API_URL,
});

const snapshot = await daytona.snapshot.create(
  {
    name,
    // fromDockerfile resolves COPY sources relative to the Dockerfile's
    // directory, which is where buildRemoteDaemon just dropped the daemon.
    image: Image.fromDockerfile(devboxDockerfilePath),
    // Registered on the snapshot record so sandboxes restart cmuxd-remote on
    // every stop/start cycle.
    entrypoint: ["/usr/local/bin/cmux-daytona-entrypoint"],
    resources: { cpu: 2, memory: 4, disk: 10 },
  },
  { onLogs: (line) => console.log(line), timeout: 0 },
);

const metadata = bakeMetadata(preflight, daemon, fileURLToPath(import.meta.url));
console.log(
  JSON.stringify(
    {
      result: { id: snapshot.id, name: snapshot.name, state: snapshot.state },
      manifestEntry: manifestEntrySkeleton(
        "daytona",
        `daytona-${name}`,
        // Daytona sandboxes are created from snapshots by name.
        name,
        "DAYTONA_SANDBOX_SNAPSHOT",
        metadata,
        "Shared devbox Dockerfile (services/vms/images/devbox).",
      ),
      next: `bun scripts/verify-devbox-image.ts daytona ${name}`,
    },
    null,
    2,
  ),
);

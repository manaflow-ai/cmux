#!/usr/bin/env bun
/**
 * Build the cmux Cloud devbox E2B template from
 * web/services/vms/images/devbox/Dockerfile.
 *
 * Usage:
 *   E2B_API_KEY=... bun scripts/build-devbox-e2b.ts [--tag <tag>] [--cache]
 *
 * Builds run with skipCache (full rebuild) BY DEFAULT: E2B's layer cache has
 * served stale npm/mise layers on "rebuilds" (chatmux, 2026-08-18). Pass
 * --cache only for config-only iterations where staleness cannot matter, and
 * follow every build with
 * `bun scripts/verify-devbox-image.ts e2b cmux-devbox:<tag>`.
 *
 * Driver contract (web/services/vms/drivers/e2b.ts): the template start
 * command runs cmuxd-remote's WebSocket PTY+RPC server on 7777 with the
 * /tmp/cmux lease files, gated on /healthz so a created sandbox is
 * attach-ready. The driver discovers lease paths from the process table.
 *
 * Resources: 2 vCPU / 4096 MB (npm OOMs below 2 GB; Chrome + the agents
 * need the headroom).
 */
import { Template, defaultBuildLogger, waitForURL } from "e2b";
import { fileURLToPath } from "node:url";
import {
  DEVBOX_SERVE_COMMAND,
  argValue,
  bakeMetadata,
  bakePreflight,
  buildRemoteDaemon,
  defaultBakeTag,
  devboxDir,
  devboxDockerfilePath,
  hasFlag,
  manifestEntrySkeleton,
} from "./devbox-image-common";

if (!process.env.E2B_API_KEY) {
  throw new Error("E2B_API_KEY is required to build the E2B devbox template");
}

const preflight = bakePreflight();
const daemon = await buildRemoteDaemon();

const tag = (argValue("--tag") ?? defaultBakeTag()).trim();
const name = `cmux-devbox:${tag}`;

const template = Template({ fileContextPath: devboxDir })
  .fromDockerfile(devboxDockerfilePath)
  .setStartCmd(DEVBOX_SERVE_COMMAND, waitForURL("http://127.0.0.1:7777/healthz", 200));

const result = await Template.build(template, name, {
  cpuCount: 2,
  memoryMB: 4096,
  skipCache: !hasFlag("--cache"),
  onBuildLogs: defaultBuildLogger({ minLevel: "info" }),
});

const metadata = bakeMetadata(preflight, daemon, fileURLToPath(import.meta.url));
console.log(
  JSON.stringify(
    {
      name,
      result,
      manifestEntry: manifestEntrySkeleton(
        "e2b",
        `e2b-${tag}`,
        name,
        "E2B_CMUXD_WS_TEMPLATE",
        metadata,
        "Shared devbox Dockerfile (services/vms/images/devbox).",
      ),
      next: `bun scripts/verify-devbox-image.ts e2b ${name}`,
    },
    null,
    2,
  ),
);

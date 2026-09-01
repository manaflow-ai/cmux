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
 * Daemon contract (web/services/vms/drivers/e2b.ts): the session daemon is
 * cmux-tui, installed by the driver at create time from the pinned
 * files.cmux.com manifest and started as a root background command; E2B
 * pause/resume preserves processes, and attach heals a dead daemon. The
 * template therefore has NO start command and bakes no daemon binary — only
 * the inert cmux-devbox-boot supervisor for uniformity with Daytona and
 * Freestyle.
 *
 * Resources: 2 vCPU / 4096 MB (npm OOMs below 2 GB; Chrome + the agents
 * need the headroom).
 */
import { Template, defaultBuildLogger } from "e2b";
import { fileURLToPath } from "node:url";
import {
  argValue,
  bakeMetadata,
  bakePreflight,
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

const tag = (argValue("--tag") ?? defaultBakeTag()).trim();
const name = `cmux-devbox:${tag}`;

const template = Template({ fileContextPath: devboxDir }).fromDockerfile(devboxDockerfilePath);

const result = await Template.build(template, name, {
  cpuCount: 2,
  memoryMB: 4096,
  skipCache: !hasFlag("--cache"),
  onBuildLogs: defaultBuildLogger({ minLevel: "info" }),
});

const metadata = bakeMetadata(preflight, fileURLToPath(import.meta.url));
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
        "Shared devbox Dockerfile (services/vms/images/devbox); cmux-tui transport.",
      ),
      next: `bun scripts/verify-devbox-image.ts e2b ${name}`,
    },
    null,
    2,
  ),
);

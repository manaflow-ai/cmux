#!/usr/bin/env bun
// Promote a smoked cmux VM image snapshot to a channel, or roll a channel back:
//   bun images/cmux-vm/promote.ts --channel dev|staging|production --snapshot <sh-id> [--var CLOUD_FREESTYLE_SNAPSHOT|TEAM_VM_SNAPSHOT]
//   bun images/cmux-vm/promote.ts --channel dev|staging|production --rollback [--var ...]
// Only changes the snapshot NEW VMs boot; never touches a running VM.
// Implementation: scripts/cmux-next/release/promote-lib.ts.
import { hostname, userInfo } from "node:os";
import { freestyleResolve, promote, runImageSmoke } from "../../scripts/cmux-next/release/promote-lib.ts";
import { REPO_ROOT } from "../../scripts/cmux-next/release/trees.ts";

process.exit(
  await promote(process.argv.slice(2), {
    root: REPO_ROOT,
    now: () => new Date(),
    smoke: runImageSmoke,
    resolve: (name) => freestyleResolve(name),
    log: (line) => console.log(line),
    error: (line) => console.error(`promote: ${line}`),
    by: `${userInfo().username}@${hostname()}`,
    env: process.env,
  }),
);

#!/usr/bin/env bun

import { applyIdeDepsPins, readIdeDeps } from "./lib/ideDeps";

async function main(): Promise<void> {
  const repoRoot = process.cwd();
  const deps = await readIdeDeps(repoRoot);
  const { dockerfileChanged, snapshotChanged } = await applyIdeDepsPins(
    repoRoot,
    deps,
  );

  if (dockerfileChanged || snapshotChanged) {
    console.log(
      `Updated pins: Dockerfile=${dockerfileChanged}, snapshot=${snapshotChanged}`,
    );
  } else {
    console.log("Pins already in sync.");
  }
}

main().catch((error) => {
  console.error("sync-ide-deps failed:", error);
  process.exit(1);
});


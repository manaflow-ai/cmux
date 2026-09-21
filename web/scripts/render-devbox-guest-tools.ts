#!/usr/bin/env bun
/**
 * Render the guest cmux tools (devbox-guest-tools.ts) for the container
 * recipe: the Dockerfile COPYs them from services/vms/images/devbox/guest-tools/,
 * which is gitignored because the files are generated shell the web services
 * already define. Run before `docker build` of the devbox recipe.
 *
 *   bun run devbox:guest-tools:render [--out <dir>]
 */
import path from "node:path";
import { DEVBOX_GUEST_TOOLS_DIR, renderDevboxGuestTools } from "./devbox-guest-tools";
import { argValue, devboxDir } from "./devbox-image-common";

const out = argValue("--out") ?? path.join(devboxDir, DEVBOX_GUEST_TOOLS_DIR);
const written = renderDevboxGuestTools(out);
for (const file of written) console.log(file);
console.log(`rendered ${written.length} guest tool files into ${out}`);

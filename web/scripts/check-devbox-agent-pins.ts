#!/usr/bin/env bun
/**
 * Compare the devbox Dockerfile's coding-agent pins (`ARG
 * CMUX_IMAGE_<TOOL>_VERSION`) with the npm registry's current release of each
 * package, and optionally rewrite them.
 *
 *   bun run devbox:pins:check            # table; exit 1 when any pin is behind
 *   bun run devbox:pins:check --write    # rewrite the ARG lines to the latest releases
 *   bun run devbox:pins:check --write --bump-epoch   # also move CMUX_IMAGE_EPOCH to today (UTC)
 *
 * Pins are exact releases (never ranges or tags), the bake installs exactly
 * them, and machines never self-update (DISABLE_AUTOUPDATER,
 * check_for_update_on_startup = false), so the only way a new Claude Code or
 * Codex reaches cmux Cloud is: bump here, bump CMUX_IMAGE_EPOCH, then
 * `bun run devbox:promote -- freestyle` for both ladders and merge the
 * manifest diff. `--write` rewrites the pins only; `--bump-epoch` also moves
 * the epoch (nextDevboxImageEpoch), which the weekly refresh workflow
 * (.github/workflows/cloud-vm-agent-refresh.yml) uses before it promotes.
 * The promotion itself stays a separate step, printed at the end.
 */
import { writeFileSync } from "node:fs";
import {
  agentPinDrift,
  devboxAgentPins,
  devboxDockerfilePath,
  devboxImageEpoch,
  hasFlag,
  nextDevboxImageEpoch,
  readDevboxDockerfile,
  rewriteDevboxAgentPins,
  rewriteDevboxImageEpoch,
  type AgentPinDrift,
} from "./devbox-image-common";

const REGISTRY = process.env.CMUX_NPM_REGISTRY?.replace(/\/+$/, "") || "https://registry.npmjs.org";

/** The registry's `latest` dist-tag for one package (`<registry>/<pkg>/latest` is the small per-version document). */
async function latestRelease(pkg: string): Promise<string> {
  const url = `${REGISTRY}/${pkg}/latest`;
  const response = await fetch(url, { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error(`${url} -> ${response.status}`);
  const body = (await response.json()) as { version?: unknown };
  if (typeof body.version !== "string" || !/^\d+\.\d+\.\d+$/.test(body.version)) {
    throw new Error(`${url}: no exact x.y.z version in the response (${JSON.stringify(body.version)})`);
  }
  return body.version;
}

function renderTable(rows: readonly AgentPinDrift[]): string {
  const width = Math.max(...rows.map((row) => row.pkg.length));
  return rows
    .map((row) => `${row.pkg.padEnd(width)}  pinned ${row.pinned.padEnd(9)} latest ${row.latest.padEnd(9)} ${row.behind ? "BEHIND" : "current"}`)
    .join("\n");
}

const dockerfile = readDevboxDockerfile();
const pins = devboxAgentPins(dockerfile);
const latest = Object.fromEntries(await Promise.all(pins.map(async (pin) => [pin.pkg, await latestRelease(pin.pkg)] as const)));
const rows = agentPinDrift(pins, latest);
console.log(`devbox agent pins (epoch ${devboxImageEpoch(dockerfile)}, registry ${REGISTRY}):\n${renderTable(rows)}`);
const behind = rows.filter((row) => row.behind);
if (behind.length === 0) {
  console.log("every pin is the registry's current release");
  process.exit(0);
}
if (!hasFlag("--write")) {
  console.log(`${behind.length} pin(s) behind; rerun with --write to rewrite them`);
  process.exit(1);
}
let next = rewriteDevboxAgentPins(dockerfile, Object.fromEntries(behind.map((row) => [row.pkg, row.latest])));
const bumpEpoch = hasFlag("--bump-epoch");
if (bumpEpoch) {
  const epoch = nextDevboxImageEpoch(devboxImageEpoch(dockerfile), new Date().toISOString().slice(0, 10));
  next = rewriteDevboxImageEpoch(next, epoch);
  console.log(`CMUX_IMAGE_EPOCH ${devboxImageEpoch(dockerfile)} -> ${epoch}`);
}
writeFileSync(devboxDockerfilePath, next);
console.log(
  `rewrote ${behind.length} pin(s) in ${devboxDockerfilePath}\n` +
    `next: ${bumpEpoch ? "" : "bump CMUX_IMAGE_EPOCH in the same file, then "}promote both ladders:\n` +
    "  FREESTYLE_API_KEY=... bun run devbox:promote -- freestyle --kinds desktop --slug cmux-devbox-<tag> --pointer-slug cmux-devbox-<tag>\n" +
    "  FREESTYLE_API_KEY=... bun run devbox:promote -- freestyle --kinds base --no-desktop --slug cmux-devbox-<tag>-base --pointer-slug cmux-devbox-<tag>-base",
);

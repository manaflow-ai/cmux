#!/usr/bin/env bun
/**
 * Compare the devbox Dockerfile's coding-agent pins (`ARG
 * CMUX_IMAGE_<TOOL>_VERSION` and `_SHA256`) with each agent's channel, its
 * GitHub releases (services/vms/images/agents.ts), and optionally rewrite them.
 *
 *   bun run devbox:pins:check            # table; exit 1 when any pin is behind
 *   bun run devbox:pins:check --write    # rewrite the ARG lines to the latest releases and their asset digests
 *
 * The channel's current release is the repository's latest release, and its
 * digest is the sha256 GitHub records for the Linux x64 asset. Set
 * GITHUB_TOKEN to lift the unauthenticated API rate limit.
 *
 * Pins are exact releases (never ranges or tags) and the bake installs exactly
 * them, so a new release reaches a machine that keeps its image's agents only
 * through a rebake: bump here, bump CMUX_IMAGE_EPOCH, then `bun run
 * devbox:promote -- freestyle` for both ladders and merge the manifest diff.
 * `--write` rewrites the pins only; the epoch bump and the promotion stay
 * explicit steps, printed at the end.
 */
import { writeFileSync } from "node:fs";
import { GITHUB_API_BASE, GUEST_AGENTS, type GuestAgent } from "../services/vms/images/agents";
import {
  agentPinDrift,
  devboxAgentPins,
  devboxDockerfilePath,
  devboxImageEpoch,
  EXACT_AGENT_PIN,
  hasFlag,
  readDevboxDockerfile,
  rewriteDevboxAgentPins,
  type AgentPinDrift,
  type AgentPinRelease,
} from "./devbox-image-common";

const API = process.env.CMUX_GITHUB_API?.replace(/\/+$/, "") || GITHUB_API_BASE;

/** The repository's latest release of one agent, with its asset's sha256. */
async function latestRelease(agent: GuestAgent): Promise<AgentPinRelease> {
  const url = `${API}/repos/${agent.repo}/releases/latest`;
  const token = process.env.GITHUB_TOKEN?.trim();
  const response = await fetch(url, {
    headers: { accept: "application/vnd.github+json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
  });
  if (!response.ok) throw new Error(`${url} -> ${response.status}`);
  const body = (await response.json()) as { tag_name?: unknown; assets?: { name?: unknown; digest?: unknown }[] };
  const tag = typeof body.tag_name === "string" ? body.tag_name : "";
  const version = tag.startsWith(agent.tagPrefix) ? tag.slice(agent.tagPrefix.length) : "";
  if (!EXACT_AGENT_PIN.test(version)) throw new Error(`${url}: latest tag ${JSON.stringify(tag)} is not ${agent.tagPrefix}<x.y.z>`);
  const digest = body.assets?.find((asset) => asset.name === agent.asset)?.digest;
  const sha256 = typeof digest === "string" ? /^sha256:([0-9a-f]{64})$/.exec(digest)?.[1] : undefined;
  if (!sha256) throw new Error(`${url}: ${tag} has no ${agent.asset} with a sha256 digest`);
  return { version, sha256 };
}

function renderTable(rows: readonly AgentPinDrift[]): string {
  const width = Math.max(...rows.map((row) => row.binary.length));
  return rows
    .map((row) => `${row.binary.padEnd(width)}  pinned ${row.pinned.padEnd(9)} latest ${row.latest.padEnd(9)} ${row.behind ? "BEHIND" : "current"}`)
    .join("\n");
}

const dockerfile = readDevboxDockerfile();
const pins = devboxAgentPins(dockerfile);
const latest = Object.fromEntries(await Promise.all(GUEST_AGENTS.map(async (agent) => [agent.npm, await latestRelease(agent)] as const)));
const rows = agentPinDrift(pins, latest);
console.log(`devbox agent pins (epoch ${devboxImageEpoch(dockerfile)}, GitHub releases via ${API}):\n${renderTable(rows)}`);
const behind = rows.filter((row) => row.behind);
if (behind.length === 0) {
  console.log("every pin is its channel's latest release");
  process.exit(0);
}
if (!hasFlag("--write")) {
  console.log(`${behind.length} pin(s) behind; rerun with --write to rewrite them`);
  process.exit(1);
}
writeFileSync(
  devboxDockerfilePath,
  rewriteDevboxAgentPins(dockerfile, Object.fromEntries(behind.map((row) => [row.pkg, { version: row.latest, sha256: row.latestSha256 }]))),
);
console.log(
  `rewrote ${behind.length} pin(s) in ${devboxDockerfilePath}\n` +
    "next: bump CMUX_IMAGE_EPOCH in the same file, then promote both ladders:\n" +
    "  FREESTYLE_API_KEY=... bun run devbox:promote -- freestyle --kinds desktop --slug cmux-devbox-<tag> --pointer-slug cmux-devbox-<tag>\n" +
    "  FREESTYLE_API_KEY=... bun run devbox:promote -- freestyle --kinds base --no-desktop --slug cmux-devbox-<tag>-base --pointer-slug cmux-devbox-<tag>-base",
);

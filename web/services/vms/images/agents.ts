/**
 * The coding agents a cmux Cloud machine carries, and the one channel each is
 * installed and updated from: the tool's own GitHub release asset for Linux
 * x86_64. The devbox bake installs the Dockerfile's pins from these assets
 * (sha256-verified), and the opt-in updater (services/vms/guestAgentUpdates.ts)
 * moves a running machine along the same channel. No step runs npm.
 *
 * Every tool publishes a standalone Linux x64 build on GitHub:
 *
 * - Claude Code: anthropics/claude-code `v<x.y.z>`, `claude-linux-x64.tar.gz`
 *   (the native build; the same release also ships SHASUMS256.txt and a PGP
 *   signature over it).
 * - Codex: openai/codex `rust-v<x.y.z>`, `codex-package-x86_64-unknown-linux-musl.tar.gz`,
 *   the package layout Codex's own installer unpacks (`bin/codex` plus its
 *   bundled ripgrep and resources).
 * - OpenCode: anomalyco/opencode `v<x.y.z>`, `opencode-linux-x64.tar.gz` (the
 *   AVX2 build; every Freestyle host has AVX2).
 * - pi: earendil-works/pi `v<x.y.z>`, `pi-linux-x64.tar.gz`, a Bun-compiled
 *   binary with its assets beside it. pi's own installer (pi.dev/install.sh)
 *   still installs from npm; this release asset is its only other channel.
 * - agent-browser: vercel-labs/agent-browser `v<x.y.z>`, the raw
 *   `agent-browser-linux-x64` binary.
 *
 * Integrity: GitHub records a sha256 `digest` for every release asset. The
 * Dockerfile pins that digest next to the version, and the updater checks the
 * bytes it downloads against the digest the releases API reports.
 */
export type GuestAgentArchive = "tar.gz" | "raw";

export type GuestAgent = {
  /** The command, and the name under /usr/local/bin and GUEST_AGENTS_ROOT. */
  readonly binary: string;
  /** The npm package older images installed; the updater migrates it. Also the pin's stable key. */
  readonly npm: string;
  /** The Dockerfile ARG carrying the exact version (CMUX_IMAGE_<TOOL>_VERSION). */
  readonly versionArg: string;
  /** The Dockerfile ARG carrying the asset's sha256 (CMUX_IMAGE_<TOOL>_SHA256). */
  readonly sha256Arg: string;
  /** owner/name on GitHub. */
  readonly repo: string;
  /** Release tag = tagPrefix + x.y.z. */
  readonly tagPrefix: string;
  /** The Linux x86_64 release asset. */
  readonly asset: string;
  readonly archive: GuestAgentArchive;
  /** The executable inside the unpacked asset (for "raw", the name the asset is saved under). */
  readonly member: string;
};

/** Dockerfile order. */
export const GUEST_AGENTS: readonly GuestAgent[] = [
  {
    binary: "claude",
    npm: "@anthropic-ai/claude-code",
    versionArg: "CMUX_IMAGE_CLAUDE_CODE_VERSION",
    sha256Arg: "CMUX_IMAGE_CLAUDE_CODE_SHA256",
    repo: "anthropics/claude-code",
    tagPrefix: "v",
    asset: "claude-linux-x64.tar.gz",
    archive: "tar.gz",
    member: "claude",
  },
  {
    binary: "codex",
    npm: "@openai/codex",
    versionArg: "CMUX_IMAGE_CODEX_VERSION",
    sha256Arg: "CMUX_IMAGE_CODEX_SHA256",
    repo: "openai/codex",
    tagPrefix: "rust-v",
    asset: "codex-package-x86_64-unknown-linux-musl.tar.gz",
    archive: "tar.gz",
    member: "bin/codex",
  },
  {
    binary: "opencode",
    npm: "opencode-ai",
    versionArg: "CMUX_IMAGE_OPENCODE_VERSION",
    sha256Arg: "CMUX_IMAGE_OPENCODE_SHA256",
    repo: "anomalyco/opencode",
    tagPrefix: "v",
    asset: "opencode-linux-x64.tar.gz",
    archive: "tar.gz",
    member: "opencode",
  },
  {
    binary: "pi",
    npm: "@earendil-works/pi-coding-agent",
    versionArg: "CMUX_IMAGE_PI_VERSION",
    sha256Arg: "CMUX_IMAGE_PI_SHA256",
    repo: "earendil-works/pi",
    tagPrefix: "v",
    asset: "pi-linux-x64.tar.gz",
    archive: "tar.gz",
    member: "pi/pi",
  },
  {
    binary: "agent-browser",
    npm: "agent-browser",
    versionArg: "CMUX_IMAGE_AGENT_BROWSER_VERSION",
    sha256Arg: "CMUX_IMAGE_AGENT_BROWSER_SHA256",
    repo: "vercel-labs/agent-browser",
    tagPrefix: "v",
    asset: "agent-browser-linux-x64",
    archive: "raw",
    member: "agent-browser",
  },
];

/** Each version unpacks to <root>/<binary>/<version>/; /usr/local/bin/<binary> links into the current one. */
export const GUEST_AGENTS_ROOT = "/opt/cmux-agents";
/** Written last into a version directory: its presence says the unpack finished and was verified. */
export const GUEST_AGENT_MARKER = ".cmux-agent.json";

export const GITHUB_API_BASE = "https://api.github.com";
export const GITHUB_DOWNLOAD_BASE = "https://github.com";

/**
 * The hosts agent installs and updates reach: release metadata from the API,
 * then the asset from github.com, which redirects to GitHub's release-asset
 * storage. All are in CMUX_REQUIRED_DOMAINS, so updates work in every network
 * mode (a test keeps the two lists together).
 */
export const GUEST_AGENT_UPDATE_DOMAINS: readonly string[] = [
  "api.github.com",
  "github.com",
  "release-assets.githubusercontent.com",
];

export function guestAgentReleaseTag(agent: GuestAgent, version: string): string {
  return `${agent.tagPrefix}${version}`;
}

export function guestAgentDownloadUrl(agent: GuestAgent, version: string, base = GITHUB_DOWNLOAD_BASE): string {
  return `${base}/${agent.repo}/releases/download/${guestAgentReleaseTag(agent, version)}/${agent.asset}`;
}

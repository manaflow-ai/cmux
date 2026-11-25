/**
 * Allowlist egress at create: the VM reaches no public address, only the exact HTTPS names listed, each steered by the
 * provider's TLS edge (a rule whose destination is the public origin of the same name, no transform). A raw IP, a name
 * not listed and DNS all fail, because the VM gets no firewall rule to the public Internet.
 *
 * The presets and the required names mirror web/services/vms/networkPolicy.ts (NETWORK_POLICY_PRESETS,
 * CMUX_REQUIRED_DOMAINS); web/tests/vm-egress-allowlist-catalog.test.ts fails when the two drift.
 */

export const EGRESS_PRESETS: Readonly<Record<string, ReadonlyArray<string>>> = Object.freeze({
  anthropic: ["api.anthropic.com", "claude.ai", "console.anthropic.com", "statsig.anthropic.com"],
  openai: ["api.openai.com", "auth.openai.com", "chatgpt.com"],
  openrouter: ["openrouter.ai"],
  opencode: ["opencode.ai", "models.dev"],
  github: [
    "github.com", "api.github.com", "codeload.github.com", "uploads.github.com",
    "raw.githubusercontent.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
  ],
  npm: ["registry.npmjs.org"],
  pypi: ["pypi.org", "files.pythonhosted.org"],
  rust: ["crates.io", "index.crates.io", "static.crates.io", "static.rust-lang.org"],
});

/** Names every allowlisted VM keeps: the guest CLI and daemon downloads and the coding agents' installs and updates. */
export const EGRESS_REQUIRED_DOMAINS: ReadonlyArray<string> = Object.freeze([
  "files.cmux.com",
  "github.com",
  "api.github.com",
  "objects.githubusercontent.com",
  "release-assets.githubusercontent.com",
]);

/** Per create; the provider's TLS rule cap is account-wide, so a VM may not take an unbounded share of it. */
export const MAX_ALLOWED_DOMAINS = 48;

const LABEL = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u;

/** An exact lowercase DNS name whose last label has a letter (never an IP address, never a wildcard). */
export const allowlistDomainOf = (value: string): string | null => {
  const lower = value.trim().toLowerCase().replace(/\.$/u, "");
  if (lower.length === 0 || lower.length > 253 || !lower.includes(".")) return null;
  const labels = lower.split(".");
  if (!labels.every((label) => label.length <= 63 && LABEL.test(label))) return null;
  return /[a-z]/u.test(labels.at(-1) ?? "") ? lower : null;
};

/**
 * The exact names an allowlist reaches: the required names, then each preset's, then the caller's, without repeats
 * and in that order. null: an unknown preset, a name that is not an exact DNS name, or more than MAX_ALLOWED_DOMAINS.
 */
export const compileAllowlist = (presets: ReadonlyArray<string>, domains: ReadonlyArray<string>): ReadonlyArray<string> | null => {
  const out: string[] = [...EGRESS_REQUIRED_DOMAINS];
  for (const id of presets) {
    const names = Object.hasOwn(EGRESS_PRESETS, id) ? EGRESS_PRESETS[id] : undefined;
    if (names === undefined) return null;
    out.push(...names);
  }
  for (const value of domains) {
    const name = allowlistDomainOf(value);
    if (name === null) return null;
    out.push(name);
  }
  const unique = [...new Set(out)];
  return unique.length > MAX_ALLOWED_DOMAINS ? null : Object.freeze(unique);
};

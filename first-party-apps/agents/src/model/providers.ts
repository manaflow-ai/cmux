// The agent CLIs this app knows by name. The owner (README "Proposed
// operations") detects them and may report CLIs that are not in this table;
// those render with the owner's display name and no install hint.
// Product names are not localized. Install hints are text the user reads;
// the app never runs them: updates and installs run in a visible terminal
// that the host opens (agent_cli.update / agent_cli.install, origin user).

export type InstallMethod = "npm" | "brew" | "native" | "cmux" | "unknown"
export type Platform = "darwin" | "linux"

export type InstallHint = { method: InstallMethod; command: string; platforms?: Platform[] }

export type Provider = {
  id: string
  name: string
  /** Executable names the owner looks for on PATH. */
  binaries: string[]
  hints: InstallHint[]
  /** Provider id of the existing `accounts.reauthenticate` action, when there is one. */
  accountsProvider: string | null
  /** Short tag for the matrix header. */
  short: string
  /** How the CLI signs in: its own login ("cli"), the cmux account ("cmux"), or not at all. */
  signIn: "cli" | "cmux" | "none"
}

export const PROVIDERS: readonly Provider[] = [
  {
    id: "claude",
    name: "Claude Code",
    short: "Claude",
    binaries: ["claude"],
    hints: [
      { method: "native", command: "curl -fsSL https://claude.ai/install.sh | bash" },
      { method: "npm", command: "npm install -g @anthropic-ai/claude-code" }
    ],
    accountsProvider: "claude",
    signIn: "cli"
  },
  {
    id: "codex",
    name: "Codex",
    short: "Codex",
    binaries: ["codex"],
    hints: [
      { method: "npm", command: "npm install -g @openai/codex" },
      { method: "brew", command: "brew install --cask codex", platforms: ["darwin"] }
    ],
    accountsProvider: "codex",
    signIn: "cli"
  },
  {
    id: "opencode",
    name: "OpenCode",
    short: "OpenCode",
    binaries: ["opencode"],
    hints: [
      { method: "npm", command: "npm install -g opencode-ai" },
      { method: "brew", command: "brew install sst/tap/opencode", platforms: ["darwin"] }
    ],
    accountsProvider: null,
    signIn: "cli"
  },
  { id: "pi", name: "Pi", short: "Pi", binaries: ["pi"], hints: [{ method: "npm", command: "npm install -g @earendil-works/pi-coding-agent" }], accountsProvider: null, signIn: "cli" },
  { id: "chief", name: "Chief", short: "Chief", binaries: ["chief"], hints: [{ method: "cmux", command: "cmux" }], accountsProvider: null, signIn: "cmux" },
  {
    id: "gemini",
    name: "Gemini CLI",
    short: "Gemini",
    binaries: ["gemini"],
    hints: [
      { method: "npm", command: "npm install -g @google/gemini-cli" },
      { method: "brew", command: "brew install gemini-cli", platforms: ["darwin"] }
    ],
    accountsProvider: "gemini",
    signIn: "cli"
  },
  { id: "amp", name: "Amp", short: "Amp", binaries: ["amp"], hints: [{ method: "npm", command: "npm install -g @sourcegraph/amp" }], accountsProvider: null, signIn: "cli" },
  { id: "copilot", name: "Copilot CLI", short: "Copilot", binaries: ["copilot"], hints: [{ method: "npm", command: "npm install -g @github/copilot" }], accountsProvider: "copilot", signIn: "cli" },
  {
    id: "cursor",
    name: "Cursor Agent",
    short: "Cursor",
    binaries: ["cursor-agent"],
    hints: [{ method: "native", command: "curl https://cursor.com/install -fsS | bash" }],
    accountsProvider: null,
    signIn: "cli"
  }
]

const BY_ID = new Map(PROVIDERS.map((p) => [p.id, p]))

export const providerFor = (id: string): Provider | null => BY_ID.get(id) ?? null

/** Table order, then unknown ids alphabetically. */
export function providerRank(id: string): number {
  const i = PROVIDERS.findIndex((p) => p.id === id)
  return i < 0 ? PROVIDERS.length : i
}

/** Whether a CLI has its own sign-in to show and repair; unknown CLIs only when the owner reports accounts. */
export const signsInItself = (id: string): boolean => (providerFor(id)?.signIn ?? "cli") === "cli"

export const displayName = (id: string, ownerName?: string | null) => providerFor(id)?.name ?? ownerName ?? id

/** Hints usable on `platform`; a `cmux` hint means the CLI ships with cmux. */
export function hintsFor(id: string, platform: Platform): InstallHint[] {
  return (providerFor(id)?.hints ?? []).filter((h) => !h.platforms || h.platforms.includes(platform))
}

/** Platform of a machine from the owner's `os` field; macOS when unknown. */
export const platformOf = (os: string | null | undefined): Platform => (String(os ?? "").toLowerCase().startsWith("linux") ? "linux" : "darwin")

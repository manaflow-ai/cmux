// l10n-allow-file: product names, the same in every language.
// The display name of an acpmux harness family; an unknown one shows as its id.
const NAMES: Record<string, string> = {
  amp: "Amp",
  claude: "Claude Code",
  codex: "Codex",
  copilot: "Copilot",
  cursor: "Cursor",
  droid: "Droid",
  gemini: "Gemini CLI",
  goose: "Goose",
  grok: "Grok",
  kilo: "Kilo",
  opencode: "OpenCode",
  pi: "Pi",
  qwen: "Qwen Code",
};

export const harnessName = (family: string) => NAMES[family] ?? family;

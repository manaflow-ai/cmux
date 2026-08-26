export type CodingAgent = {
  slug: string;
  name: string;
  seoName?: string;
  command?: string;
  path?: string;
  genericPage?: boolean;
};

export const codingAgents: readonly CodingAgent[] = [
  { slug: "claude-code", name: "Claude Code", command: "claude" },
  { slug: "codex", name: "Codex", seoName: "Codex CLI", command: "codex" },
  { slug: "grok", name: "Grok", seoName: "Grok Build CLI", command: "grok", genericPage: true },
  { slug: "cursor-cli", name: "Cursor", seoName: "Cursor CLI", command: "cursor-agent" },
  { slug: "github-copilot", name: "GitHub Copilot", command: "copilot", genericPage: true },
  { slug: "opencode", name: "OpenCode", command: "opencode" },
  { slug: "mimo-code", name: "MiMo Code", genericPage: true },
  { slug: "amp", name: "Amp", command: "amp" },
  { slug: "openclaude", name: "OpenClaude", genericPage: true },
  { slug: "openclaw", name: "OpenClaw", genericPage: true },
  { slug: "antigravity", name: "Antigravity", seoName: "Antigravity CLI", command: "agy", genericPage: true },
  { slug: "pi", name: "Pi", seoName: "Pi coding agent", command: "pi" },
  {
    slug: "oh-my-pi",
    name: "oh-my-pi",
    path: "/docs/agent-integrations/oh-my-pi",
  },
  { slug: "hermes", name: "Hermes", seoName: "Hermes Agent", command: "hermes", genericPage: true },
  { slug: "devin", name: "Devin", genericPage: true },
  { slug: "goose", name: "Goose", command: "goose", genericPage: true },
  { slug: "auggie", name: "Auggie", seoName: "Auggie CLI", command: "auggie", genericPage: true },
  { slug: "autohand-code", name: "Autohand Code", command: "autohand", genericPage: true },
  { slug: "charm", name: "Charm", seoName: "Charm coding agent", genericPage: true },
  { slug: "cline", name: "Cline", command: "cline", genericPage: true },
  { slug: "codebuff", name: "Codebuff", command: "codebuff", genericPage: true },
  { slug: "command-code", name: "Command Code", genericPage: true },
  { slug: "continue", name: "Continue", command: "cn", genericPage: true },
  { slug: "droid", name: "Droid", seoName: "Factory Droid", command: "droid", genericPage: true },
  { slug: "kilo-code", name: "Kilo Code", command: "kilocode", genericPage: true },
  { slug: "kimi", name: "Kimi", seoName: "Kimi Code CLI", command: "kimi", genericPage: true },
  { slug: "kiro", name: "Kiro", command: "kiro-cli", genericPage: true },
  { slug: "mistral-vibe", name: "Mistral Vibe", command: "vibe", genericPage: true },
  { slug: "qwen-code", name: "Qwen Code", command: "qwen", genericPage: true },
  { slug: "rovo-dev", name: "Rovo Dev", command: "acli rovodev run", genericPage: true },
  { slug: "gemini-cli", name: "Gemini CLI", command: "gemini" },
  { slug: "aider", name: "Aider", command: "aider" },
  { slug: "openhands", name: "OpenHands", genericPage: true },
  { slug: "roo-code", name: "Roo Code", genericPage: true },
];

export const genericCodingAgents = codingAgents.filter(
  (agent) => agent.genericPage,
);

export function codingAgentPath(agent: CodingAgent) {
  return agent.path ?? `/agents/${agent.slug}`;
}

export function findGenericCodingAgent(slug: string) {
  return genericCodingAgents.find((agent) => agent.slug === slug);
}

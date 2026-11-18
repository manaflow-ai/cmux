// Claude's long-lived setup token (cmux-tui/docs/model-connections.md, Revision 2): the person runs
// Claude Code's own `claude setup-token` and pastes what it prints. Settings > Models (ModelsCard.tsx
// ClaudeTokenForm) and the chat's model picker (ClaudeConnectDialog.tsx) both check a pasted value
// here before it is sent; the app checks it again before it reaches the Keychain.

/** The command that prints a setup token. A product command, shown as it is in every language. */
export const CLAUDE_SETUP_TOKEN_COMMAND = "claude setup-token";

/** Claude's setup token starts with this, and a pasted one has no whitespace in it. */
const CLAUDE_TOKEN = /^sk-ant-oat\S*$/;

/** Whether `token` reads as a Claude setup token (`claude setup-token` prints one). */
export function isClaudeToken(token: string): boolean {
  return CLAUDE_TOKEN.test(token);
}

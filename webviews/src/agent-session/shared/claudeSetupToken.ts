// Claude's long-lived setup token (cmux-tui/docs/model-connections.md, Revision 2): the person runs
// Claude Code's own `claude setup-token` and pastes what it prints. Settings > Models (ModelsCard.tsx
// ClaudeTokenForm) and the chat's model picker (ClaudeConnectDialog.tsx) both check a pasted value
// here before it is sent; the app checks it again before it reaches the Keychain.

/** The command that prints a setup token. A product command, shown as it is in every language. */
export const CLAUDE_SETUP_TOKEN_COMMAND = "claude setup-token";

/** Claude's setup token starts with this and has no whitespace of its own. */
const CLAUDE_TOKEN = /^sk-ant-oat\S*$/;

/**
 * The token in a pasted value: every whitespace character taken out, inner ones too. A terminal
 * wraps `claude setup-token`'s long line and pads it with spaces and newlines, and a copy keeps
 * them; a token never has whitespace of its own, so none of it is ever part of the token.
 */
export function pastedClaudeToken(field: string): string {
  return field.replace(/\s+/gu, "");
}

/** Whether `token` reads as a Claude setup token (`claude setup-token` prints one). */
export function isClaudeToken(token: string): boolean {
  return CLAUDE_TOKEN.test(token);
}

// Claude's long-lived setup token (cmux-tui/docs/model-connections.md, Revision 2): the person runs
// Claude Code's own `claude setup-token` and pastes what it prints. Settings > Models (ModelsCard.tsx
// ClaudeTokenForm) and the chat's model picker (ClaudeConnectDialog.tsx) both check a pasted value
// here before it is sent; the app checks it again before it reaches the Keychain.

/** The command that prints a setup token. A product command, shown as it is in every language. */
export const CLAUDE_SETUP_TOKEN_COMMAND = "claude setup-token";

/** Claude's setup token: `sk-ant-oat`, two digits, a dash, then base64url (letters, digits, `-`, `_`). */
const CLAUDE_TOKEN = /^sk-ant-oat\d{2}-[A-Za-z0-9_-]+$/;

/** Every space, tab, line break and invisible space (zero-width, BOM) a terminal copy can put in. */
const PASTE_NOISE = /[\s\u200B-\u200D\u2060\uFEFF]+/g;

/** A pasted setup token with every whitespace character taken out, wherever it is: a terminal that
 * wrapped the token across lines, padded it with spaces or added a trailing newline gives back the
 * one token it printed. A token never holds whitespace, so nothing real is removed. */
export function normalizeClaudeToken(pasted: string): string {
  return pasted.replace(PASTE_NOISE, "");
}

/** Whether `token`, once normalized, reads as a Claude setup token (`claude setup-token` prints one). */
export function isClaudeToken(token: string): boolean {
  return CLAUDE_TOKEN.test(normalizeClaudeToken(token));
}

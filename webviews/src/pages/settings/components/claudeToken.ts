import type { ClaudeTokenState, ModelsState } from "../ops";

/** No Connect Claude run: what a host that omits `claudeToken` reads as. */
const CLAUDE_IDLE: ClaudeTokenState = { attempt: null, phase: null, error: null };

/** The page's Connect Claude run: `models.claudeToken`, idle on a host that omits it. */
export const claudeTokenOf = (models: ModelsState): ClaudeTokenState => models.claudeToken ?? CLAUDE_IDLE;

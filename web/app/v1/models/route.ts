import { proxyCodexModels } from "@/services/coderouter/codexProxy";
import {
  anthropicError,
  isAnthropicRequest,
  proxyClaudeModels,
} from "@/services/coderouter/claudeProxy";

export const maxDuration = 60;

// Anthropic clients (the SDK, Claude Code) always send `anthropic-version`;
// those get the Anthropic-shaped catalog for the team's Claude upstream.
// Every other caller keeps the Codex behaviour.
export async function GET(request: Request): Promise<Response> {
  if (isAnthropicRequest(request)) {
    try {
      return await proxyClaudeModels(request);
    } catch {
      return anthropicError(503, "api_error", "coderouter is temporarily unavailable. Retry shortly.");
    }
  }
  return await proxyCodexModels(request);
}

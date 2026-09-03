import { anthropicError, proxyClaudeCountTokens } from "../../../../services/coderouter/claudeProxy";

export const maxDuration = 60;

export async function POST(request: Request): Promise<Response> {
  try {
    return await proxyClaudeCountTokens(request);
  } catch {
    return anthropicError(503, "api_error", "coderouter is temporarily unavailable. Retry shortly.");
  }
}

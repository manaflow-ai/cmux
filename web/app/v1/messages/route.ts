import { anthropicError, proxyClaudeMessages } from "../../../services/coderouter/claudeProxy";

export const maxDuration = 1_800;

export async function POST(request: Request): Promise<Response> {
  try {
    return await proxyClaudeMessages(request);
  } catch {
    return anthropicError(503, "api_error", "coderouter is temporarily unavailable. Retry shortly.");
  }
}

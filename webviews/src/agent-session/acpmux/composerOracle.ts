// The agent composer's part of the refactor oracle's `webviews` facet (protocol/oracle-state.ts):
// the chat it belongs to, by its durable session id, as the selection, and the
// prompt as the draft (sent only as its SHA-256). Its pickers and popovers report themselves as
// panels (ui/oraclePanel.ts).
import type { OracleStateReading } from "../../protocol/oracle-state";

/** The composer's reading: `sessionId` (none for a chat not made yet) and the prompt's text. */
export function composerOracleReading(sessionId: string | undefined, prompt: string): OracleStateReading {
  return { selection: sessionId ?? null, draft: prompt };
}

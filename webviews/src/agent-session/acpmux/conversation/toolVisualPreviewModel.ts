import { mediaKind } from "../chips/replyMediaModel";

/** Keep audio and video in their existing players, including inline MCP media. */
export function isStillVisual(source: string): boolean {
  return source.startsWith("data:image/") || (!source.startsWith("data:") && !mediaKind(source));
}

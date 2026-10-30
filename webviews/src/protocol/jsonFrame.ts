// One JSON text frame of a WebSocket that carries one JSON object per frame (acpmux, the daemon,
// the diff sidecar). A frame that is not JSON, or is JSON but not an object (`null`, `0`, `[]`,
// `"text"`), returns null instead of throwing, so the socket's message callback never throws on
// a peer's bad frame and the caller decides what a bad frame means.

export function parseJsonObjectFrame(text: string): Record<string, unknown> | null {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

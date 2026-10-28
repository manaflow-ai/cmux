// Fixture for test/pane-english.test.ts: shapes the scanner must flag.
class RunApiHttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export function snapshotFailed(status: number, error: { message?: string }) {
  // An Error's text through `??`: the fallback shows when the server sends no message.
  throw new RunApiHttpError(status, error.message ?? `Run snapshot failed (${status})`);
}

export function readFailed(error: { message?: string }) {
  // An Error's text through `||`, as a plain sentence.
  throw new Error(error.message || "Could not read the run");
}

export function shownMessage(error: { message?: string }) {
  // A message with an English fallback, handed on for display.
  const text = error.message ?? "Run board is unavailable";
  return { title: text };
}

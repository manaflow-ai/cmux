// A file whose upload failed retries by itself. The native upload gate keeps a short retry credit
// for an upload that already had a real gesture, so a timer retry cannot be mistaken for a new
// agent command or surface the internal "agent connection" refusal to the person.

/// How many times a failed upload is tried again on its own before its chip shows Retry.
export const UPLOAD_AUTO_RETRIES = 2;
/// The first retry delay. Later retries use exponential backoff.
export const UPLOAD_RETRY_DELAY_MS = 1_000;
export const uploadRetryDelay = (tries: number) => UPLOAD_RETRY_DELAY_MS * 2 ** Math.max(0, tries);

/// Runs `again` for try `tries` (0 is the first try again) of a failed upload, or `giveUp` once the
/// bounded retries are spent. Answers what stops a retry still waiting (the chip's x).
export function retryUploadLater(tries: number, again: () => void, giveUp: () => void): () => void {
  if (tries >= UPLOAD_AUTO_RETRIES) {
    giveUp();
    return () => {};
  }
  let done = false;
  const stop = () => {
    done = true;
    clearTimeout(timer);
  };
  const timer = setTimeout(() => {
    if (done) return;
    done = true;
    again();
  }, uploadRetryDelay(tries));
  return stop;
}

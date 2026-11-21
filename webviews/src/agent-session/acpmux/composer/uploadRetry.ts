// A file whose upload failed tries again on its own before its chip shows Retry (Leo,
// 2026-11-01, after a pasted mp4 failed until he clicked Retry: "i had to retry to get it to
// load???"). Each try goes on a timer, 1 s and then 2 s after the failure. The host no longer
// spends a key press or click on an upload's begin (#45429), so a try no longer waits for the
// person's next key or click, and a chip shows Retry only once its own tries are spent.

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

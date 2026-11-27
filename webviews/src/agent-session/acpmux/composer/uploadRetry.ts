// A file whose upload failed tries again on its own before its chip shows Retry (Leo,
// 2026-11-01, after a pasted mp4 failed until he clicked Retry: "i had to retry to get it to
// load???"). The host starts an upload only on the person's fresh key or click (its begin spends
// that gesture, AgentPaneModel `uploadStage`), so every try again waits for the person's next key
// or click in the page, as the chip's Retry click would. One sent on a timer with no gesture was
// always refused ("The app refused the agent connection."), and that refusal took the place of
// the upload's own error on its tile (Leo, 2026-10-31: "idk what's going on with video
// attachments"). Return never starts one: its send keeps that gesture for the prompt.

/// How many times a failed upload is tried again on its own before its chip shows Retry.
export const UPLOAD_AUTO_RETRIES = 2;
/// How long after the failure a try again goes where there is no page to hear input (a test host).
export const UPLOAD_RETRY_DELAY_MS = 1_000;
/// How long a try again waits for the person's next key or click before the chip shows Retry.
export const UPLOAD_RETRY_INPUT_WAIT_MS = 15_000;

const MODIFIER_KEYS = new Set(["Shift", "Control", "Alt", "Meta", "CapsLock", "Fn"]);

/// Runs `again` for try `tries` (0 is the first try again) of a failed upload, or `giveUp` once the
/// tries are spent or the wait for input ends. Answers what stops a try still waiting (the chip's x).
export function retryUploadLater(
  tries: number,
  again: () => void,
  giveUp: () => void,
  doc: Document | undefined = typeof document === "undefined" ? undefined : document,
): () => void {
  if (tries >= UPLOAD_AUTO_RETRIES) {
    giveUp();
    return () => {};
  }
  if (!doc) {
    const timer = setTimeout(again, UPLOAD_RETRY_DELAY_MS);
    return () => clearTimeout(timer);
  }
  let done = false;
  const stop = () => {
    done = true;
    clearTimeout(timer);
    doc.removeEventListener("keydown", input, true);
    doc.removeEventListener("pointerdown", input, true);
  };
  function input(event: Event) {
    if (done || !event.isTrusted) return;
    const key = event.type === "keydown" ? (event as KeyboardEvent) : undefined;
    // A lone modifier reaches AppKit as flagsChanged, not keyDown: the host records no gesture for it.
    if (key && (key.key === "Enter" || key.repeat || MODIFIER_KEYS.has(key.key))) return;
    stop();
    // After the host recorded this key or click: the try begins with it.
    setTimeout(again, 0);
  }
  doc.addEventListener("keydown", input, true);
  doc.addEventListener("pointerdown", input, true);
  const timer = setTimeout(() => {
    stop();
    giveUp();
  }, UPLOAD_RETRY_INPUT_WAIT_MS);
  return stop;
}

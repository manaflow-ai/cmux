// Before the app ends a Messages page's document (a conversation tab or the Chief panel closing,
// HomeConversationPage.close), it asks the page to hand everything it holds alone to its next owner:
//
//   home.messages.settle {within?: ms} -> {held: string | null}
//
// The page saves the drafts typed since the last pause now, then answers once nothing lives only in
// it any more (the same holds that keep a web update's reload waiting, main.tsx: a draft not yet
// saved, a staged file or a send the app has not said it holds), or at `within` with the hold that
// is left. The app closes the page after the answer, so nothing goes before the app holds it.

export const SETTLE_OP = "home.messages.settle";

/** The longest a settle waits when the host names no bound. */
export const SETTLE_DEFAULT_MS = 5_000;
/** How often a settle looks again at what the page still holds alone. */
const SETTLE_STEP_MS = 50;

/** Saves now (`flush`), then waits until `held` answers null or `within` ms passed. */
export async function settle(
  flush: () => void,
  held: () => string | null,
  params: unknown,
  wait: (ms: number) => Promise<void> = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
): Promise<{ held: string | null }> {
  const asked = params && typeof params === "object" ? (params as { within?: unknown }).within : undefined;
  const within = typeof asked === "number" && Number.isFinite(asked) && asked >= 0 ? asked : SETTLE_DEFAULT_MS;
  flush();
  let waited = 0;
  let reason = held();
  while (reason && waited < within) {
    await wait(SETTLE_STEP_MS);
    waited += SETTLE_STEP_MS;
    reason = held();
  }
  return { held: reason };
}

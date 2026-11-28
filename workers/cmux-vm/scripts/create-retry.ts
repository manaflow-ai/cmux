/**
 * A smoke create that meets a full create queue waits and sends again, as cmux-platform's Cloud driver does for every
 * user create (backoff up to 300 s). Without this, production smoke right after a deploy failed on the deploy's own
 * journey burst: run 46077839592 answered 503 "vm-provider.createQueueFull" to both smoke creates at 22:49Z, two
 * minutes after journey-production started its creates. Every create here carries an idempotency key, so a resend
 * cannot make a second VM.
 */

export type Answer = { readonly status: number; readonly body: unknown };

/** The 503 cmux-vm answers when the provider create queue refuses a slot (src/handlers/vms.ts). */
export const isCreateQueueFull = (answer: Answer): boolean =>
  answer.status === 503 && JSON.stringify(answer.body ?? "").includes("createQueueFull");

export const retryWhileQueueFull = async (
  send: () => Promise<Answer>,
  options: { readonly budgetMs?: number; readonly waitMs?: number; readonly now?: () => number; readonly sleep?: (ms: number) => Promise<void>; readonly log?: (line: string) => void } = {},
): Promise<Answer> => {
  const budgetMs = options.budgetMs ?? 300_000, waitMs = options.waitMs ?? 10_000;
  const now = options.now ?? Date.now;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const log = options.log ?? ((line: string) => console.log(line));
  const deadline = now() + budgetMs;
  for (let tries = 1; ; tries++) {
    const answer = await send();
    if (!isCreateQueueFull(answer) || now() + waitMs > deadline) return answer;
    log(`    create queue full (try ${tries}); sending again in ${Math.round(waitMs / 1000)} s`);
    await sleep(waitMs);
  }
};

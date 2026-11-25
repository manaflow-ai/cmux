import { expect, test } from "bun:test";
import { cloudCredentialRecovery } from "./cloudCredentialRecovery";
import type { AcpmuxDirectClient } from "./direct";

test("automatic rejected-login recovery transfers and retries only once", async () => {
  let transfers = 0;
  let retries = 0;
  const client = {
    selectedSession: "session",
    resendPrompt: async (_rowId: string, prompt: string) => ({ input: prompt, attachments: [] }),
    send: async (..._args: Parameters<AcpmuxDirectClient["send"]>) => {
      retries += 1;
      return undefined;
    },
  };
  const attempts = new Set<string>();
  const recovery = cloudCredentialRecovery(
    true,
    "machine",
    "session",
    "claude",
    async (_method, params) => {
      transfers += 1;
      return { transferred: true, promptId: params.retryPromptId, ticket: "ticket" };
    },
    (session) => session === "session",
    () => client,
    attempts,
  );
  const rebuiltRecovery = cloudCredentialRecovery(
    true,
    "machine",
    "session",
    "claude",
    async (_method, params) => {
      transfers += 1;
      return { transferred: true, promptId: params.retryPromptId, ticket: "ticket" };
    },
    (session) => session === "session",
    () => client,
    attempts,
  );

  expect(recovery).toBeDefined();
  expect(rebuiltRecovery).toBeDefined();
  await recovery!("prompt-row", "Try again", true);
  await rebuiltRecovery!("retried-prompt-row", "Try again", true);

  expect(transfers).toBe(1);
  expect(retries).toBe(1);
});

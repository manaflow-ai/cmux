/** Restore references durable daemon evidence; never send editable paths or patch text. */
export type TestTamperingRestoreTarget = {
  eventSeq: number;
  fileIndex: number;
  findingIndex: number;
};

export const TEST_TAMPERING_RESTORE_METHOD = "_acpmux/test_tampering_restore";

export async function restoreTestTampering(
  request: (method: string, params: Record<string, unknown>, deadline?: number) => Promise<unknown>,
  sessionId: string,
  target: TestTamperingRestoreTarget,
): Promise<void> {
  const reply = await request(TEST_TAMPERING_RESTORE_METHOD, { sessionId, ...target }, 15_000);
  if (!reply || typeof reply !== "object" || !("restored" in reply) || reply.restored !== true) {
    // l10n-allow: protocol failure; the card supplies its localized failure message.
    throw new Error("Test restore was not confirmed");
  }
}

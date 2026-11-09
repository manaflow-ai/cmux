import { afterEach, expect, test } from "bun:test";
import { attachmentRetry, withAttachmentRetries } from "./attachmentRetry";

const delays = attachmentRetry.delaysMs;
afterEach(() => {
  attachmentRetry.delaysMs = delays;
});

test("a read that fails for a moment is tried again on its own and answers", async () => {
  attachmentRetry.delaysMs = [1, 1, 1];
  let tries = 0;
  const value = await withAttachmentRetries(async () => {
    tries += 1;
    if (tries < 3) throw new Error("socket closed");
    return "data:image/png;base64,AA==";
  });
  expect(value).toBe("data:image/png;base64,AA==");
  expect(tries).toBe(3);
});

test("the tries stop after the last wait and the last error comes back", async () => {
  attachmentRetry.delaysMs = [1, 1, 1];
  let tries = 0;
  const failed = withAttachmentRetries(async () => {
    tries += 1;
    throw new Error(`try ${tries}`);
  });
  await expect(failed).rejects.toThrow("try 4");
  expect(tries).toBe(4);
});

test("an abort or an error it should not retry ends at once", async () => {
  attachmentRetry.delaysMs = [1, 1, 1];
  let tries = 0;
  await expect(
    withAttachmentRetries(async () => {
      tries += 1;
      throw new DOMException("cancelled", "AbortError");
    }),
  ).rejects.toThrow("cancelled");
  await expect(
    withAttachmentRetries(
      async () => {
        tries += 1;
        throw new Error("too large");
      },
      { retries: () => false },
    ),
  ).rejects.toThrow("too large");
  expect(tries).toBe(2);
});

test("an abort while a try again waits ends the tries at once", async () => {
  attachmentRetry.delaysMs = [60_000];
  const controller = new AbortController();
  let tries = 0;
  const failed = withAttachmentRetries(
    async () => {
      tries += 1;
      // Aborted before its wait starts: the wait never begins.
      controller.abort();
      throw new Error("socket closed");
    },
    { signal: controller.signal },
  );
  await expect(failed).rejects.toThrow("socket closed");
  expect(tries).toBe(1);
});

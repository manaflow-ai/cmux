import { afterEach, describe, expect, test } from "bun:test";
import {
  KnownErrors,
} from "@stackframe/stack-shared";
import { runAsynchronouslyWithAlert } from "@stackframe/stack-shared/dist/utils/promises";

const originalNodeEnv = process.env.NODE_ENV;
const originalAlert = globalThis.alert;
const mutableProcessEnv = process.env as unknown as Record<string, string | undefined>;

afterEach(() => {
  if (originalNodeEnv === undefined) {
    delete mutableProcessEnv.NODE_ENV;
  } else {
    mutableProcessEnv.NODE_ENV = originalNodeEnv;
  }
  globalThis.alert = originalAlert;
});

async function captureAlert(error: Error): Promise<string> {
  let message: string | undefined;
  globalThis.alert = (value: string) => {
    message = value;
  };

  runAsynchronouslyWithAlert(Promise.reject(error), { noErrorLogging: true });
  await Promise.resolve();
  await Promise.resolve();

  return message ?? "";
}

describe("Stack Auth async error alerts", () => {
  test("shows a typed error when the browser has no process environment", async () => {
    delete mutableProcessEnv.NODE_ENV;
    const error = new KnownErrors.UserWithEmailAlreadyExists(
      "buyer@example.com",
      true,
    );

    expect(await captureAlert(error)).toBe(error.message);
  });

  test("keeps development diagnostics for typed errors", async () => {
    mutableProcessEnv.NODE_ENV = "development";
    const error = new KnownErrors.UserWithEmailAlreadyExists(
      "buyer@example.com",
      true,
    );

    const message = await captureAlert(error);
    expect(message).toContain("An unhandled error occurred.");
    expect(message).toContain(error.message);
  });

  test("keeps unknown errors generic when the environment is unavailable", async () => {
    delete mutableProcessEnv.NODE_ENV;
    const error = new Error("provider internals must stay private");

    const message = await captureAlert(error);
    expect(message).toContain("An unhandled error occurred.");
    expect(message).toContain(error.message);
  });
});

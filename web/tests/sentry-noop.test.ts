import { describe, expect, mock, test } from "bun:test";

describe("Sentry no-op paths", () => {
  test("does not load or initialize Sentry when SENTRY_DSN is unset", async () => {
    const previousDsn = process.env.SENTRY_DSN;
    const previousRuntime = process.env.NEXT_RUNTIME;
    const previousConsoleError = console.error;
    let sentryLoads = 0;
    const init = mock(() => undefined);
    const captureException = mock(() => undefined);
    const captureRequestError = mock(() => undefined);
    const withScope = mock(() => undefined);

    mock.module("@sentry/nextjs", () => {
      sentryLoads += 1;
      return {
        init,
        captureException,
        captureRequestError,
        withScope,
      };
    });

    try {
      delete process.env.SENTRY_DSN;
      process.env.NEXT_RUNTIME = "nodejs";
      console.error = mock(() => undefined) as unknown as typeof console.error;

      const [{ register }, { reportError }] = await Promise.all([
        import("../instrumentation"),
        import("../services/observability/report"),
      ]);

      await register();
      reportError(new Error("test error"), { subsystem: "test" });
      await Promise.resolve();

      expect(sentryLoads).toBe(0);
      expect(init).not.toHaveBeenCalled();
      expect(captureException).not.toHaveBeenCalled();
      expect(captureRequestError).not.toHaveBeenCalled();
      expect(withScope).not.toHaveBeenCalled();
    } finally {
      console.error = previousConsoleError;
      if (previousDsn === undefined) {
        delete process.env.SENTRY_DSN;
      } else {
        process.env.SENTRY_DSN = previousDsn;
      }

      if (previousRuntime === undefined) {
        delete process.env.NEXT_RUNTIME;
      } else {
        process.env.NEXT_RUNTIME = previousRuntime;
      }
    }
  });
});

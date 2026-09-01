import { afterEach, describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import {
  KnownErrors,
} from "@stackframe/stack-shared";
import { runAsynchronouslyWithAlert } from "@stackframe/stack-shared/dist/utils/promises";

const originalNodeEnv = process.env.NODE_ENV;
const originalAlert = globalThis.alert;
const originalWindow = (globalThis as typeof globalThis & {
  window?: unknown;
}).window;
const mutableProcessEnv = process.env as unknown as Record<string, string | undefined>;
const mutableGlobalThis = globalThis as typeof globalThis & {
  window?: unknown;
};

afterEach(() => {
  if (originalNodeEnv === undefined) {
    Reflect.deleteProperty(mutableProcessEnv, "NODE_ENV");
  } else {
    mutableProcessEnv.NODE_ENV = originalNodeEnv;
  }
  globalThis.alert = originalAlert;
  if (originalWindow === undefined) {
    Reflect.deleteProperty(mutableGlobalThis, "window");
  } else {
    mutableGlobalThis.window = originalWindow;
  }
});

/** Captures the sanitized alert emitted for a non-recoverable async failure. */
async function captureAlert(error: Error): Promise<string> {
  let resolveAlert: (message: string) => void = () => {};
  const alertPromise = new Promise<string>((resolve) => {
    resolveAlert = resolve;
  });
  globalThis.alert = resolveAlert;

  runAsynchronouslyWithAlert(Promise.reject(error), { noErrorLogging: true });
  return await alertPromise;
}

/** Captures the same-origin recovery redirect without opening a browser. */
async function captureRedirect(
  error: Error,
  href = "https://cmux.com/handler/sign-in",
): Promise<{
  readonly url: string;
  readonly alertCalled: boolean;
}> {
  let resolveRedirect: (url: string) => void = () => {};
  const redirectPromise = new Promise<string>((resolve) => {
    resolveRedirect = resolve;
  });
  let alertCalled = false;
  globalThis.alert = () => {
    alertCalled = true;
  };
  mutableGlobalThis.window = {
    location: {
      href,
      replace: resolveRedirect,
    },
  } as unknown as typeof globalThis.window;

  runAsynchronouslyWithAlert(Promise.reject(error), { noErrorLogging: true });
  return { url: await redirectPromise, alertCalled };
}

describe("Stack Auth async error alerts", () => {
  test("promotes credential-signup duplicate results without retaining the error", async () => {
    const source = await readFile(
      fileURLToPath(
        new URL(
          "../node_modules/@stackframe/stack/dist/esm/components/credential-sign-up.js",
          import.meta.url,
        ),
      ),
      "utf8",
    );
    const duplicateResultBranch =
      'if (result.error.errorCode === "USER_EMAIL_ALREADY_EXISTS") {';

    expect(source).toContain(duplicateResultBranch);
    expect(source).toContain(
      "runAsynchronouslyWithAlert(Promise.reject(result.error), { noErrorLogging: true });",
    );
    expect(source).not.toContain("throw result.error;");
    expect(
      source.indexOf(duplicateResultBranch),
    ).toBeLessThan(source.indexOf('message: result.error.message'));
  });

  test("redirects an email conflict to localized recovery guidance", async () => {
    Reflect.deleteProperty(mutableProcessEnv, "NODE_ENV");
    const error = new KnownErrors.UserWithEmailAlreadyExists(
      "buyer@example.com",
      true,
    );

    const result = await captureRedirect(
      error,
      "https://cmux.com/handler/sign-in?after_auth_return_to=%2Fhandler%2Fafter-sign-in%3Fnonce%3Dopaque&web_return_to=%2Fdashboard",
    );
    const redirect = new URL(result.url);
    expect(redirect.pathname).toBe("/handler/auth-error");
    expect(redirect.searchParams.get("code")).toBe("email-conflict");
    expect(redirect.searchParams.get("after_auth_return_to")).toBe(
      "/handler/after-sign-in?nonce=opaque",
    );
    expect(redirect.searchParams.get("web_return_to")).toBe("/dashboard");
    expect(result.url).not.toContain(error.message);
    expect(result.url).not.toContain("buyer@example.com");
    expect(result.alertCalled).toBe(false);
  });

  test("uses the same recovery path for a verified duplicate-email conflict", async () => {
    Reflect.deleteProperty(mutableProcessEnv, "NODE_ENV");
    const error = new KnownErrors.UserWithEmailAlreadyExists(
      "buyer@example.com",
      false,
    );

    const result = await captureRedirect(error);
    expect(new URL(result.url).searchParams.get("code")).toBe("email-conflict");
    expect(result.alertCalled).toBe(false);
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
    Reflect.deleteProperty(mutableProcessEnv, "NODE_ENV");
    const error = new Error("provider internals must stay private");

    const message = await captureAlert(error);
    expect(message).toContain("An unhandled error occurred.");
    expect(message).not.toContain(error.message);
  });

  test("preserves actionable known errors when the browser environment is unavailable", async () => {
    Reflect.deleteProperty(mutableProcessEnv, "NODE_ENV");
    const error = new KnownErrors.EmailNotVerified();

    expect(await captureAlert(error)).toBe(error.message);
  });

  test("preserves actionable known errors in an explicit production environment", async () => {
    mutableProcessEnv.NODE_ENV = "production";
    const error = new KnownErrors.EmailNotVerified();

    expect(await captureAlert(error)).toBe(error.message);
  });
});

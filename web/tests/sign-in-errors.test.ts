import { describe, expect, test } from "bun:test";
import { KnownErrors } from "@hexclave/shared";
import enMessages from "../messages/en.json";
import {
  PRODUCTION_STACK_PROJECT_ID,
  refusedRedirectOrigin,
  signInFailureMessage,
} from "../app/handler/sign-in-errors";
import { DEVELOPMENT_STACK_PROJECT_ID } from "../services/auth/stackProject";

const messages = enMessages.cmuxSignIn;

describe("sign-in failure messages", () => {
  test("a refused redirect names the refused origin and the backend, not the generic error", () => {
    const refused = new KnownErrors.RedirectUrlNotWhitelisted("https://cmux-staging.vercel.app/handler/sign-in?after_auth_return_to=x");
    expect(
      signInFailureMessage(refused, messages, {
        projectId: DEVELOPMENT_STACK_PROJECT_ID,
        pageOrigin: "https://cmux-staging.vercel.app",
      }),
    ).toBe("This build's sign-in address isn't allowed on the development backend. (https://cmux-staging.vercel.app)");
    expect(
      signInFailureMessage(refused, messages, { projectId: PRODUCTION_STACK_PROJECT_ID, pageOrigin: null }),
    ).toBe("This build's sign-in address isn't allowed on cmux.com. (https://cmux-staging.vercel.app)");
  });

  test("a refusal without the URL names the page's own origin", () => {
    const refused = new KnownErrors.RedirectUrlNotWhitelisted();
    expect(refusedRedirectOrigin(refused, "https://cmux-dev-backend-1.tail137216.ts.net:4123")).toBe(
      "https://cmux-dev-backend-1.tail137216.ts.net:4123",
    );
    expect(signInFailureMessage(refused, messages, { projectId: DEVELOPMENT_STACK_PROJECT_ID, pageOrigin: null })).toBe(
      "This build's sign-in address isn't allowed on the development backend.",
    );
  });

  test("every other failure keeps the generic text", () => {
    const context = { projectId: DEVELOPMENT_STACK_PROJECT_ID, pageOrigin: "https://cmux.com" };
    expect(signInFailureMessage(new Error("boom"), messages, context)).toBe(messages.errorGeneric);
    expect(signInFailureMessage(new KnownErrors.EmailPasswordMismatch(), messages, context)).toBe(messages.errorGeneric);
    expect(signInFailureMessage(undefined, messages, context)).toBe(messages.errorGeneric);
  });

  test("a catalog without the sentence falls back to the generic text", () => {
    const refused = new KnownErrors.RedirectUrlNotWhitelisted("https://x.test/handler/sign-in");
    expect(
      signInFailureMessage(refused, { errorGeneric: "generic" }, { projectId: undefined, pageOrigin: null }),
    ).toBe("generic");
  });
});

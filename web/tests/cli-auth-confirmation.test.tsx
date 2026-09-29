import { beforeEach, describe, expect, mock, test } from "bun:test";
import type { CliAuthConfirmationState } from "@hexclave/next";
import React from "react";
import en from "../messages/en.json";
import ja from "../messages/ja.json";
import { renderToStaticMarkup } from "react-dom/server";

let auth: CliAuthConfirmationState;
let user: {
  primaryEmail: string | null;
  selectedTeam: { displayName: string } | null;
} | null;

mock.module("@hexclave/next", () => ({
  useCliAuthConfirmation: () => auth,
  useUser: () => user,
  MessageCard: ({ title, children, primaryButtonText, secondaryButtonText }: {
    title: string;
    children: React.ReactNode;
    primaryButtonText?: string;
    secondaryButtonText?: string;
  }) => <main><h1>{title}</h1>{children}{secondaryButtonText && <button type="button">{secondaryButtonText}</button>}{primaryButtonText && <button type="button">{primaryButtonText}</button>}</main>,
}));

const { CliAuthConfirmation } = await import("../app/handler/cli-auth-confirmation");

beforeEach(() => {
  auth = {
    status: "idle",
    loginCode: "test-login-code",
    error: null,
    isLoading: false,
    authorize: mock(async () => {}),
    retry: mock(() => {}),
  };
  user = { primaryEmail: "alex@example.com", selectedTeam: { displayName: "Example team" } };
});

describe("CLI authorization account identity", () => {
  for (const status of ["idle", "invalid", "authorizing", "redirecting", "success", "error"] as const) {
    test(`shows the authenticating account on the ${status} screen`, () => {
      auth.status = status;
      auth.isLoading = status === "authorizing" || status === "redirecting";
      const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);

      expect(html).toContain("alex@example.com");
      expect(html).toContain("Example team");
      expect(html.match(/alex@example\.com/g)).toHaveLength(1);
    });
  }

  test("shows the account before the Authorize action", () => {
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(html).toContain("alex@example.com");
    expect(html.indexOf("alex@example.com")).toBeLessThan(html.indexOf('<button type="button">Authorize</button>'));
  });

  test("offers a different-account sign-in that preserves the CLI login code", () => {
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(html).toContain("<button type=\"button\">Use a different account</button>");
  });

  test("builds a different-account sign-in that preserves the CLI login code", async () => {
    const { cliAuthSwitchAccountHref } = await import("../app/handler/cli-auth-confirmation");
    const switchURL = new URL(cliAuthSwitchAccountHref("test-login-code"), "https://cmux.test");
    expect(switchURL.pathname).toBe("/handler/sign-out-and-sign-in");

    const signInURL = new URL(
      switchURL.searchParams.get("after_auth_return_to")!,
      "https://cmux.test",
    );
    expect(signInURL.pathname).toBe("/handler/sign-in");

    const confirmationURL = new URL(
      signInURL.searchParams.get("after_auth_return_to")!,
      "https://cmux.test",
    );
    expect(confirmationURL.pathname).toBe("/handler/cli-auth-confirm");
    expect(confirmationURL.searchParams.get("login_code")).toBe("test-login-code");
  });

  test("uses the current session account when it changes", () => {
    renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    user = { primaryEmail: "blair@example.com", selectedTeam: null };
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(html).toContain("blair@example.com");
    expect(html).toContain("personal account");
    expect(html).not.toContain("alex@example.com");
  });

  test("retains safe fallbacks when no email or organization is available", () => {
    user = { primaryEmail: null, selectedTeam: null };
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(html).toContain("email unavailable");
    expect(html).toContain("personal account");
  });

  test("asks a signed-out browser to sign in instead of showing a placeholder account", () => {
    user = null;
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(html).toContain(en.cliAuthIdentity.signedOutTitle);
    expect(html).toContain(`<button type="button">${en.cliAuthIdentity.signInButton}</button>`);
    expect(html).not.toContain("email unavailable");
    expect(html).not.toContain("personal account");
    expect(html).not.toContain('<button type="button">Authorize</button>');
  });

  for (const signedIn of [true, false]) {
    for (const status of ["idle", "authorizing", "redirecting", "error"] as const) {
      test(`offers a different account on the ${status} screen when ${signedIn ? "signed in" : "signed out"}`, () => {
        if (!signedIn) user = null;
        auth.status = status;
        const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
        expect(html).toContain(`<button type="button">${en.cliAuthIdentity.switchAccountButton}</button>`);
      });
    }
  }

  test("does not offer a different account after the login code is consumed", () => {
    auth.status = "success";
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(html).not.toContain(en.cliAuthIdentity.switchAccountButton);
  });

  test("keeps the signed-out sign-in action wired to CLI authorization", () => {
    user = null;
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(html).toContain(en.cliAuthIdentity.signedOutBody);
    auth.status = "redirecting";
    auth.isLoading = true;
    const redirecting = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(redirecting).toContain("Completing Authorization...");
    expect(redirecting).not.toContain("email unavailable");
  });

  test("keeps the account visible without exposing raw authorization errors", () => {
    auth.status = "error";
    auth.error = new Error("private token from upstream");
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(html).toContain("alex@example.com");
    expect(html).toContain("Try Again");
    expect(html).not.toContain("private token from upstream");
  });

  test("localizes labels and missing account details", () => {
    user = { primaryEmail: null, selectedTeam: null };
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={ja.cliAuthIdentity} />);
    const { signedOutTitle, signedOutBody, signInButton, ...signedInMessages } = ja.cliAuthIdentity;
    for (const message of Object.values(signedInMessages)) {
      expect(html).toContain(message);
    }
    expect(html).not.toContain(en.cliAuthIdentity.emailUnavailable);

    user = null;
    const signedOut = renderToStaticMarkup(<CliAuthConfirmation identityMessages={ja.cliAuthIdentity} />);
    for (const message of [signedOutTitle, signedOutBody, signInButton]) {
      expect(signedOut).toContain(message);
    }
    expect(signedOut).not.toContain(en.cliAuthIdentity.signedOutTitle);
  });
});

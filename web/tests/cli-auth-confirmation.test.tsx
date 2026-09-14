import { beforeEach, describe, expect, mock, test } from "bun:test";
import type { CliAuthConfirmationState } from "@stackframe/stack";
import React from "react";
import en from "../messages/en.json";
import ja from "../messages/ja.json";
import { renderToStaticMarkup } from "react-dom/server";

let auth: CliAuthConfirmationState;
let user: {
  primaryEmail: string | null;
  selectedTeam: { displayName: string } | null;
} | null;

mock.module("@stackframe/stack", () => ({
  useCliAuthConfirmation: () => auth,
  useUser: () => user,
  MessageCard: ({ title, children, primaryButtonText }: {
    title: string;
    children: React.ReactNode;
    primaryButtonText?: string;
  }) => <main><h1>{title}</h1>{children}{primaryButtonText && <button type="button">{primaryButtonText}</button>}</main>,
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

  test("uses the current session account when it changes", () => {
    renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    user = { primaryEmail: "blair@example.com", selectedTeam: null };
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(html).toContain("blair@example.com");
    expect(html).toContain("personal account");
    expect(html).not.toContain("alex@example.com");
  });

  test("retains safe fallbacks when no email or organization is available", () => {
    user = null;
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={en.cliAuthIdentity} />);
    expect(html).toContain("email unavailable");
    expect(html).toContain("personal account");
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
    user = null;
    const html = renderToStaticMarkup(<CliAuthConfirmation identityMessages={ja.cliAuthIdentity} />);
    for (const message of Object.values(ja.cliAuthIdentity)) {
      expect(html).toContain(message);
    }
    expect(html).not.toContain(en.cliAuthIdentity.emailUnavailable);
  });
});

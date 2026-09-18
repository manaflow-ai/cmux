import { beforeEach, describe, expect, mock, test } from "bun:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { CliAuthIdentityMessages } from "../app/handler/cli-auth-confirmation";
import ja from "../messages/ja.json";

const pendingStackRender = new Promise<never>(() => {});
let requestHeaders = new Headers();
let receivedIdentityMessages: CliAuthIdentityMessages | undefined;
let authenticated = true;
let redirectedTo: string | undefined;

mock.module("../app/handler/cli-auth-confirmation", () => ({
  CliAuthConfirmation: ({ identityMessages }: { identityMessages: CliAuthIdentityMessages }) => {
    receivedIdentityMessages = identityMessages;
    throw pendingStackRender;
  },
}));

mock.module("@stackframe/stack", () => ({
  MagicLinkSignIn: () => React.createElement("div"),
  StackHandler: () => {
    throw pendingStackRender;
  },
}));

mock.module("next/headers", () => ({
  headers: async () => requestHeaders,
}));

mock.module("next/navigation", () => ({
  notFound: () => {
    throw new Error("unexpected notFound");
  },
  redirect: (target: string) => {
    redirectedTo = target;
    throw new Error(`redirected to ${target}`);
  },
}));

mock.module("next/server", () => ({
  connection: async () => {},
}));

mock.module("../app/lib/stack", () => ({
  stackServerApp: {
    getUser: async () => authenticated ? { id: "user-1" } : null,
  },
}));

const { default: StackHandlerPage } = await import(
  "../app/handler/[...stack]/page"
);

beforeEach(() => {
  requestHeaders = new Headers();
  receivedIdentityMessages = undefined;
  authenticated = true;
  redirectedTo = undefined;
});

describe("Stack handler page", () => {
  test("passes the browser's preferred language to CLI account identity", async () => {
    requestHeaders.set("accept-language", "ja,en;q=0.8");
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["cli-auth-confirm"] }),
      searchParams: Promise.resolve({ login_code: "test-login-code" }),
    });

    renderToStaticMarkup(page);
    expect(receivedIdentityMessages).toEqual(ja.cliAuthIdentity);
  });

  test("renders a loading state while CLI authorization resolves the account", async () => {
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["cli-auth-confirm"] }),
      searchParams: Promise.resolve({ login_code: "test-login-code" }),
    });

    expect(renderToStaticMarkup(page)).toContain('aria-busy="true"');
  });

  test("redirects unauthenticated CLI authorization requests before rendering", async () => {
    authenticated = false;

    await expect(StackHandlerPage({
      params: Promise.resolve({ stack: ["cli-auth-confirm"] }),
      searchParams: Promise.resolve({ login_code: "test-login-code" }),
    })).rejects.toThrow("redirected to");

    expect(redirectedTo).toBe(
      "/handler/sign-in?after_auth_return_to=%2Fhandler%2Fcli-auth-confirm%3Flogin_code%3Dtest-login-code",
    );
    expect(receivedIdentityMessages).toBeUndefined();
  });

  test("renders a loading state while Stack's client component suspends", async () => {
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["email-verification"] }),
      searchParams: Promise.resolve({}),
    });

    expect(renderToStaticMarkup(page)).toContain('aria-busy="true"');
  });

  test("renders a loading state when any Stack handler path suspends", async () => {
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["team-invitation"] }),
      searchParams: Promise.resolve({}),
    });

    expect(renderToStaticMarkup(page)).toContain('aria-busy="true"');
  });

  test("keeps an unlisted future handler path behind the same boundary", async () => {
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["future-handler"] }),
      searchParams: Promise.resolve({}),
    });

    expect(renderToStaticMarkup(page)).toContain('aria-busy="true"');
  });
});

import { beforeEach, describe, expect, mock, test } from "bun:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { CliAuthIdentityMessages } from "../app/handler/cli-auth-confirmation";
import type { CmuxSignInMessages } from "../app/handler/cmux-sign-in";
import de from "../messages/de.json";
import ja from "../messages/ja.json";

const pendingStackRender = new Promise<never>(() => {});
let requestHeaders = new Headers();
let receivedIdentityMessages: CliAuthIdentityMessages | undefined;
let receivedSignIn: { mode: string; messages: CmuxSignInMessages } | undefined;

mock.module("../app/handler/cli-auth-confirmation", () => ({
  CliAuthConfirmation: ({ identityMessages }: { identityMessages: CliAuthIdentityMessages }) => {
    receivedIdentityMessages = identityMessages;
    throw pendingStackRender;
  },
}));

mock.module("../app/handler/cmux-sign-in", () => ({
  CmuxSignIn: (props: { mode: string; messages: CmuxSignInMessages }) => {
    receivedSignIn = props;
    return React.createElement("div", { "data-cmux-sign-in": props.mode });
  },
  CmuxOAuthCallback: () => React.createElement("div", { "data-cmux-oauth-callback": "" }),
}));

mock.module("@hexclave/next", () => ({
  MagicLinkSignIn: () => React.createElement("div"),
  MessageCard: () => React.createElement("div"),
  useCliAuthConfirmation: () => null,
  useUser: () => null,
  StackHandler: () => {
    throw pendingStackRender;
  },
}));

mock.module("next/headers", () => ({
  headers: async () => requestHeaders,
}));

let redirectedTo: string | undefined;
mock.module("next/navigation", () => ({
  notFound: () => {
    throw new Error("unexpected notFound");
  },
  redirect: (target: string) => {
    redirectedTo = target;
    throw new Error(`redirect:${target}`);
  },
}));

mock.module("next/server", () => ({
  connection: async () => {},
}));

mock.module("../app/lib/stack", () => ({
  stackServerApp: {},
}));

const { default: StackHandlerPage } = await import(
  "../app/handler/[...stack]/page"
);

beforeEach(() => {
  requestHeaders = new Headers();
  receivedIdentityMessages = undefined;
  receivedSignIn = undefined;
  redirectedTo = undefined;
});

describe("Stack handler page", () => {
  test("passes the browser's preferred language to CLI account identity", async () => {
    requestHeaders.set("accept-language", "ja,en;q=0.8");
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["cli-auth-confirm"] }),
    });

    renderToStaticMarkup(page);
    expect(receivedIdentityMessages).toEqual(ja.cliAuthIdentity);
  });

  test("renders a loading state while CLI authorization resolves the account", async () => {
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["cli-auth-confirm"] }),
    });

    expect(renderToStaticMarkup(page)).toContain('aria-busy="true"');
  });

  test("renders a loading state while Stack's client component suspends", async () => {
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["email-verification"] }),
    });

    expect(renderToStaticMarkup(page)).toContain('aria-busy="true"');
  });

  test("renders a loading state when any Stack handler path suspends", async () => {
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["team-invitation"] }),
    });

    expect(renderToStaticMarkup(page)).toContain('aria-busy="true"');
  });

  test("keeps an unlisted future handler path behind the same boundary", async () => {
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["future-handler"] }),
    });

    expect(renderToStaticMarkup(page)).toContain('aria-busy="true"');
  });

  test("sign-in and sign-up render cmux's own screen in the browser's language", async () => {
    requestHeaders.set("accept-language", "de,en;q=0.8");
    for (const mode of ["sign-in", "sign-up"]) {
      const page = await StackHandlerPage({ params: Promise.resolve({ stack: [mode] }) });
      expect(renderToStaticMarkup(page)).toContain(`data-cmux-sign-in="${mode}"`);
      expect(receivedSignIn?.mode).toBe(mode);
      expect(receivedSignIn?.messages).toEqual(de.cmuxSignIn);
    }
  });

  test("the coderouter host keeps its email-only sign-in", async () => {
    requestHeaders.set("host", "coderouter.dev");
    const page = await StackHandlerPage({ params: Promise.resolve({ stack: ["sign-in"] }) });
    expect(renderToStaticMarkup(page)).not.toContain("data-cmux-sign-in");
    expect(receivedSignIn).toBeUndefined();
  });

  test("nested and other handler paths stay with the hosted handler", async () => {
    for (const stack of [["sign-in", "extra"], ["magic-link-callback"], ["forgot-password"]]) {
      const page = await StackHandlerPage({ params: Promise.resolve({ stack }) });
      expect(renderToStaticMarkup(page)).toContain('aria-busy="true"');
    }
    expect(receivedSignIn).toBeUndefined();
  });

  test("the OAuth return is cmux's own page", async () => {
    const page = await StackHandlerPage({ params: Promise.resolve({ stack: ["oauth-callback"] }) });
    expect(renderToStaticMarkup(page)).toContain("data-cmux-oauth-callback");
  });

  test("a refused OAuth return goes to cmux's recovery page, without the provider's text", async () => {
    const searchParams = Promise.resolve({
      error: "server_error",
      error_description: 'This email "(a@b.com)" is already used for authentication by another account',
    });
    await expect(
      StackHandlerPage({ params: Promise.resolve({ stack: ["oauth-callback"] }), searchParams }),
    ).rejects.toThrow("redirect:");
    expect(redirectedTo).toBe("/handler/auth-error?code=email-unverified");
  });
});

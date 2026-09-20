import { beforeEach, describe, expect, mock, test } from "bun:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { CliAuthIdentityMessages } from "../app/handler/cli-auth-confirmation";
import ja from "../messages/ja.json";

const pendingStackRender = new Promise<never>(() => {});
let requestHeaders = new Headers();
let receivedIdentityMessages: CliAuthIdentityMessages | undefined;

mock.module("../app/handler/cli-auth-confirmation", () => ({
  CliAuthConfirmation: ({ identityMessages }: { identityMessages: CliAuthIdentityMessages }) => {
    receivedIdentityMessages = identityMessages;
    throw pendingStackRender;
  },
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

mock.module("next/navigation", () => ({
  notFound: () => {
    throw new Error("unexpected notFound");
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
});

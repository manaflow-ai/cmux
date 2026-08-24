import { describe, expect, mock, test } from "bun:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

const pendingStackRender = new Promise<never>(() => {});

mock.module("@stackframe/stack", () => ({
  MagicLinkSignIn: () => React.createElement("div"),
  StackHandler: () => {
    throw pendingStackRender;
  },
}));

mock.module("next/headers", () => ({
  headers: async () => new Headers(),
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

describe("email verification handler page", () => {
  test("contains Stack's client-side session suspension", async () => {
    const page = await StackHandlerPage({
      params: Promise.resolve({ stack: ["email-verification"] }),
    });

    expect(renderToStaticMarkup(page)).toBe("");
  });
});

import { beforeEach, describe, expect, mock, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

type MockUser = { isRestricted?: boolean };

class RedirectError extends Error {
  constructor(readonly href: string) {
    super("redirect");
  }
}

const redirect = mock((href: unknown) => {
  throw new RedirectError(String(href));
});

let currentHost = "cmux.test";
let currentUser: MockUser | null = { isRestricted: false };
let getUserRejects = false;

mock.module("next/navigation", () => ({
  redirect,
  notFound: () => null,
  permanentRedirect: redirect,
}));

mock.module("next/headers", () => ({
  headers: async () =>
    new Headers({
      host: currentHost,
    }),
  cookies: async () => ({
    get: () => undefined,
    getAll: () => [],
    has: () => false,
  }),
  draftMode: async () => ({ isEnabled: false }),
}));

mock.module("@stackframe/stack", () => ({
  StackHandler: () => createElement("div", null, "stack handler rendered"),
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser: async () => currentUser }),
  getStackHandlerApp: () => ({
    getUser: async () => {
      if (getUserRejects) throw new Error("getUser failed");
      return currentUser;
    },
  }),
  isStackConfigured: () => true,
  isStackHandlerConfigured: () => true,
  stackServerApp: { getUser: async () => currentUser },
  stackHandlerApp: {
    getUser: async () => {
      if (getUserRejects) throw new Error("getUser failed");
      return currentUser;
    },
  },
}));

const { resolveSignedInForwardTarget } = await import("../app/lib/signed-in-forward");
const { default: StackHandlerPage } = await import("../app/handler/[...stack]/page");

function nativeAfterSignInTarget(): string {
  return "/handler/after-sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback%3Fcmux_auth_state%3Dabc";
}

async function renderPage(pathSegments: string[], afterAuthReturnTo?: string) {
  return StackHandlerPage({
    params: Promise.resolve({ stack: pathSegments }),
    searchParams: Promise.resolve(
      afterAuthReturnTo === undefined ? {} : { after_auth_return_to: afterAuthReturnTo },
    ),
  });
}

async function expectRedirect(pathSegments: string[], afterAuthReturnTo: string, href: string) {
  await expect(renderPage(pathSegments, afterAuthReturnTo)).rejects.toMatchObject({ href });
  expect(redirect).toHaveBeenCalledWith(href);
}

async function expectRender(pathSegments: string[], afterAuthReturnTo?: string) {
  const element = await renderPage(pathSegments, afterAuthReturnTo);
  const html = renderToStaticMarkup(element);
  expect(html).toContain("stack handler rendered");
  expect(redirect).not.toHaveBeenCalled();
}

describe("Stack handler signed-in forwarding", () => {
  beforeEach(() => {
    redirect.mockClear();
    currentHost = "cmux.test";
    currentUser = { isRestricted: false };
    getUserRejects = false;
  });

  test("redirects signed-in sign-in requests with a relative native after-sign-in target", async () => {
    const target = nativeAfterSignInTarget();

    await expectRedirect(["sign-in"], target, target);
  });

  test("redirects signed-in sign-up requests with a relative native after-sign-in target", async () => {
    const target = nativeAfterSignInTarget();

    await expectRedirect(["sign-up"], target, target);
  });

  test("redirects same-host absolute native after-sign-in targets to the relative URL", async () => {
    await expectRedirect(
      ["sign-in"],
      `https://cmux.test${nativeAfterSignInTarget()}`,
      nativeAfterSignInTarget(),
    );
  });

  test("renders instead of redirecting absolute foreign-host targets", async () => {
    await expectRender(["sign-in"], `https://evil.example${nativeAfterSignInTarget()}`);
  });

  test("renders instead of redirecting targets outside the native after-sign-in page", async () => {
    await expectRender(["sign-in"], "/dashboard?native_app_return_to=cmux%3A%2F%2Fauth-callback");
    await expectRender(
      ["sign-in"],
      "/handler/sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback",
    );
  });

  test("renders instead of redirecting after-sign-in targets missing native_app_return_to", async () => {
    await expectRender(["sign-in"], "/handler/after-sign-in?cmux_auth_handoff=handoff");
  });

  test("renders when getUser resolves null", async () => {
    currentUser = null;

    await expectRender(["sign-in"], nativeAfterSignInTarget());
  });

  test("renders when the user is restricted", async () => {
    currentUser = { isRestricted: true };

    await expectRender(["sign-in"], nativeAfterSignInTarget());
  });

  test("renders when getUser rejects", async () => {
    getUserRejects = true;

    await expectRender(["sign-in"], nativeAfterSignInTarget());
  });

  test("does not redirect non-auth handler paths", async () => {
    await expectRender(["oauth-callback"], nativeAfterSignInTarget());
  });
});

describe("resolveSignedInForwardTarget", () => {
  test("rejects multi-value after_auth_return_to params", async () => {
    const target = await resolveSignedInForwardTarget({
      pathSegments: ["sign-in"],
      searchParams: { after_auth_return_to: [nativeAfterSignInTarget()] },
      requestHost: "cmux.test",
      getUser: async () => ({}),
    });

    expect(target).toBeNull();
  });

  test("rejects protocol-relative targets", async () => {
    const target = await resolveSignedInForwardTarget({
      pathSegments: ["sign-in"],
      searchParams: { after_auth_return_to: "//evil.example/handler/after-sign-in" },
      requestHost: "cmux.test",
      getUser: async () => ({}),
    });

    expect(target).toBeNull();
  });
});

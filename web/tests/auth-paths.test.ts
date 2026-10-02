import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

import middleware from "../proxy";
import {
  AUTH_PAGE_HANDLERS,
  HEXCLAVE_AUTH_PAGE_URLS,
  authPathRedirects,
  isSignInPath,
} from "../app/lib/auth-paths";
import { handlerHref } from "../app/handler/sign-in-entry";
import sitemap from "../app/sitemap";

/**
 * Where next.config's redirects send a path, or null when none matches. Every
 * source is a literal path (checked below), so Next matches it exactly.
 */
function redirectFor(pathname: string): ReturnType<typeof authPathRedirects>[number] | null {
  return authPathRedirects().find((rule) => rule.source === pathname) ?? null;
}

describe("canonical auth URLs", () => {
  test("every sign-in alias 308s to /sign-in", () => {
    for (const alias of ["/login", "/log-in", "/signin", "/handler/sign-in"]) {
      expect(redirectFor(alias)).toEqual({ source: alias, destination: "/sign-in", permanent: true });
    }
  });

  test("every sign-up alias 308s to /sign-up", () => {
    for (const alias of ["/signup", "/register", "/create-account", "/handler/sign-up"]) {
      expect(redirectFor(alias)).toEqual({ source: alias, destination: "/sign-up", permanent: true });
    }
  });

  test("the canonical pages are never redirected, so the rewrite cannot loop", () => {
    expect(redirectFor("/sign-in")).toBeNull();
    expect(redirectFor("/sign-up")).toBeNull();
  });

  test("every other handler route stays with the handler", () => {
    for (const path of [
      "/handler/oauth-callback",
      "/handler/magic-link-callback",
      "/handler/email-verification",
      "/handler/password-reset",
      "/handler/forgot-password",
      "/handler/after-sign-in",
      "/handler/native-sign-in",
      "/handler/sign-out",
      "/handler/sign-out-and-sign-in",
      "/handler/cli-auth-confirm",
      "/handler/auth-error",
      "/handler/sign-in/extra",
    ]) {
      expect(redirectFor(path)).toBeNull();
    }
  });

  test("sources are literal and destinations carry no query, so Next keeps the request's own", () => {
    for (const rule of authPathRedirects()) {
      expect(rule.source).toMatch(/^\/[a-z/-]+$/);
      expect(rule.destination).not.toContain("?");
      expect(rule.destination).not.toContain(":");
    }
  });

  test("/sign-in renders the handler's sign-in page with its query intact", () => {
    const response = middleware(
      new NextRequest(
        "https://cmux.test/sign-in?after_auth_return_to=%2Fdashboard&prompt=select_account",
        { headers: { "accept-language": "ja" } },
      ),
    );

    expect(response.headers.get("location")).toBeNull();
    const rewritten = new URL(response.headers.get("x-middleware-rewrite")!);
    expect(rewritten.pathname).toBe("/handler/sign-in");
    expect(rewritten.searchParams.get("after_auth_return_to")).toBe("/dashboard");
    expect(rewritten.searchParams.get("prompt")).toBe("select_account");
  });

  test("/sign-up renders the handler's sign-up page", () => {
    const response = middleware(new NextRequest("https://cmux.test/sign-up?native_app_return_to=x"));

    expect(response.headers.get("location")).toBeNull();
    const rewritten = new URL(response.headers.get("x-middleware-rewrite")!);
    expect(rewritten.pathname).toBe("/handler/sign-up");
    expect(rewritten.searchParams.get("native_app_return_to")).toBe("x");
  });

  test("the proxy maps only the two canonical paths", () => {
    expect([...AUTH_PAGE_HANDLERS.entries()]).toEqual([
      ["/sign-in", "sign-in"],
      ["/sign-up", "sign-up"],
    ]);
  });

  test("Hexclave's own sign-in and sign-up links use the canonical pages", () => {
    expect(HEXCLAVE_AUTH_PAGE_URLS.signIn.url).toBe("/sign-in");
    expect(HEXCLAVE_AUTH_PAGE_URLS.signUp.url).toBe("/sign-up");
  });

  test("the forms cross-link the canonical pages and keep the return target", () => {
    expect(handlerHref("sign-in", "/dashboard")).toBe("/sign-in?after_auth_return_to=%2Fdashboard");
    expect(handlerHref("sign-up", null)).toBe("/sign-up");
    expect(handlerHref("forgot-password", null)).toBe("/handler/forgot-password");
  });

  test("sign-in path checks accept the canonical and the legacy path", () => {
    expect(isSignInPath("/sign-in")).toBe(true);
    expect(isSignInPath("/handler/sign-in")).toBe(true);
    expect(isSignInPath("/login")).toBe(false);
  });

  // Every sitemap URL must have agent-readable .md/.txt variants, which a
  // sign-in form has no content for, so the pages are found through their
  // canonical tags and links instead. No alias may be listed either.
  test("the sitemap lists no auth page or alias", () => {
    const urls = sitemap().map((entry) => new URL(String(entry.url)).pathname);
    expect(urls.some((path) => /\/(sign-in|sign-up|login|log-in|signin|signup|register|create-account)$|^\/handler\//.test(path))).toBe(false);
  });
});

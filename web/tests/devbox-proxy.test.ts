import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";
import { shouldRewriteToDevbox } from "../devbox-routing";
import { vaultSignInHref } from "../app/lib/vault-auth";

describe("devbox.new host routing", () => {
  test("rewrites the devbox.new homepage to the devbox creator", () => {
    expect(shouldRewriteToDevbox("devbox.new", "/")).toBe(true);
    expect(shouldRewriteToDevbox("www.devbox.new", "/")).toBe(true);
    expect(shouldRewriteToDevbox("devbox.new:443", "/")).toBe(true);
  });

  test("does not rewrite cmux.com or API paths", () => {
    expect(shouldRewriteToDevbox("cmux.com", "/")).toBe(false);
    expect(shouldRewriteToDevbox("devbox.new", "/api/vm")).toBe(false);
    expect(shouldRewriteToDevbox("devbox.new", "/handler/sign-in")).toBe(false);
  });
});

// Exercise the current middleware entrypoint, including the locale router.
describe("devbox creator middleware integration", () => {
  test.each(["devbox.new", "www.devbox.new"])("rewrites %s home and preserves the query", (host) => {
    const response = middleware(new NextRequest(`https://${host}/?ref=create`, {
      headers: { host, "accept-language": "ja" },
    }));
    expect(response.headers.get("x-middleware-rewrite")).toBe(`https://${host}/devbox?ref=create`);
    expect(response.headers.get("location")).toBeNull();
  });

  test.each(["devbox.new", "cmux.com", "preview.vercel.app"])("serves the auth return path on %s without localization", (host) => {
    for (const path of ["/devbox", "/devbox/"]) {
      const response = middleware(new NextRequest(`https://${host}${path}`, {
        headers: { host, "accept-language": "ja" },
      }));
      expect(response.headers.get("x-middleware-next")).toBe("1");
      expect(response.headers.get("x-middleware-rewrite")).toBeNull();
      expect(response.headers.get("location")).toBeNull();
    }
  });

  test("keeps the cmux.dev canonical redirect ahead of creator routing", () => {
    const response = middleware(new NextRequest("https://cmux.dev/devbox", {
      headers: { host: "cmux.dev" },
    }));
    expect(response.status).toBe(301);
    expect(response.headers.get("location")).toBe("https://cmux.com/devbox");
  });

  test("sign-in passes through account setup before returning to the creator", () => {
    const signIn = new URL(vaultSignInHref("/devbox"), "https://devbox.new");
    expect(signIn.pathname).toBe("/handler/sign-in");
    const afterSignIn = new URL(signIn.searchParams.get("after_auth_return_to")!, signIn);
    expect(afterSignIn.pathname).toBe("/handler/after-sign-in");
    expect(afterSignIn.searchParams.get("after_auth_return_to")).toBe("/devbox");
  });
});

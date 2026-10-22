import { describe, expect, mock, test } from "bun:test";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";
import { renderToStaticMarkup } from "react-dom/server";
import { acceptOrigin, forwardUrl, isInviteCode } from "../app/i/invite-link";

const CODE = "d01JB8Q3Z5X7Y9K2M4N6P8R0T2V";
const SECRET = "0123456789ABCDEFGHJKMNPQRS";

const notFound = mock(() => {
  throw Object.assign(new Error("not found"), { notFound: true });
});
const redirect = mock((href: unknown) => {
  throw Object.assign(new Error("redirect"), { href });
});
// bun's mock.module is process-wide: keep the shared export set complete.
mock.module("next/navigation", () => ({ ...createNextNavigationMock(redirect), notFound }));

const { default: InvitePage, generateMetadata } = await import("../app/i/[code]/page");
const { inviteHeaders, securityHeaderRules } = await import("../security-headers");
const { config } = await import("../proxy");

describe("cmux.com/i invite links", () => {
  test("accepts only well-formed codes", () => {
    expect(isInviteCode(CODE)).toBe(true);
    expect(isInviteCode("g01JB8Q3Z5X7Y9K2M4N6P8R0T2V")).toBe(true);
    for (const bad of ["x01JB8Q3Z5X7Y9K2M4N6P8R0T2V", "d01JB", `${CODE}A`, "d01jb8q3z5x7y9k2m4n6p8r0t2v"]) {
      expect(isInviteCode(bad)).toBe(false);
    }
  });

  test("forwards to the accept origin with the secret fragment only when well formed", () => {
    expect(forwardUrl("https://console.cmux.dev", CODE, `#${SECRET}`)).toBe(
      `https://console.cmux.dev/i/${CODE}#${SECRET}`,
    );
    expect(forwardUrl("https://console.cmux.dev", CODE, "#<script>")).toBe(`https://console.cmux.dev/i/${CODE}`);
    expect(forwardUrl("https://console.cmux.dev", "nope", `#${SECRET}`)).toBeNull();
  });

  test("uses a configured bare https accept origin, else production", () => {
    expect(acceptOrigin("https://console-staging.cmux.dev")).toBe("https://console-staging.cmux.dev");
    for (const bad of [undefined, "", "http://console.cmux.dev", "https://evil.example.com/x", "not a url"]) {
      expect(acceptOrigin(bad)).toBe("https://console.cmux.dev");
    }
  });

  test("serves Open Graph tags for message previews and stays out of search", async () => {
    const meta = await generateMetadata({ params: Promise.resolve({ code: CODE }) });
    expect(meta.openGraph?.url).toBe(`https://cmux.com/i/${CODE}`);
    expect(JSON.stringify(meta.openGraph?.images)).toContain("https://cmux.com/opengraph-image");
    expect(meta.robots).toEqual({ index: false, follow: false });
  });

  test("renders the invite card with the forward link", async () => {
    const html = renderToStaticMarkup(await InvitePage({ params: Promise.resolve({ code: CODE }) }));
    expect(html).toContain("invited to a conversation on cmux");
    expect(html).toContain(`href="https://console.cmux.dev/i/${CODE}"`);
    await expect(InvitePage({ params: Promise.resolve({ code: "x" }) })).rejects.toMatchObject({ notFound: true });
  });

  test("invite pages are private: no shared cache, no index, no referrer", () => {
    const rule = securityHeaderRules.find((r) => r.source === "/i/:code");
    expect(rule?.headers).toEqual(inviteHeaders);
    expect(securityHeaderRules.indexOf(rule!)).toBeGreaterThan(securityHeaderRules.findIndex((r) => r.source === "/:path*"));
    expect(inviteHeaders).toContainEqual({ key: "Cache-Control", value: "private, no-store, max-age=0" });
  });

  test("the proxy matcher leaves /i/ outside the localized site", () => {
    const pattern = new RegExp(`^${config.matcher[0]}$`);
    expect(pattern.test(`/i/${CODE}`)).toBe(false);
    expect(pattern.test("/install")).toBe(true);
    expect(pattern.test("/en/docs")).toBe(true);
  });
});

import { describe, expect, test } from "bun:test";

process.env.SKIP_ENV_VALIDATION = "1";
const { default: config } = await import("../next.config");

type Redirect = { source: string; destination: string; permanent: boolean };

describe("/linux while Linux is waitlist-only", () => {
  test("is a temporary HTTP redirect to /browser for every locale form", async () => {
    // withSentryConfig / next-intl wrap the config; redirects() stays callable.
    const redirects = (await (config as { redirects: () => Promise<Redirect[]> }).redirects());
    const linux = redirects.filter((r) => /\/linux(\.md|\.txt)?$/.test(r.source));
    const pairs = linux.map((r) => [r.source.replace(/:locale\([^)]*\)/, ":locale"), r.destination, r.permanent]);
    expect(pairs).toContainEqual(["/linux", "/browser", false]);
    expect(pairs).toContainEqual(["/en/linux", "/browser", false]);
    expect(pairs).toContainEqual(["/:locale/linux", "/:locale/browser", false]);
    expect(pairs).toContainEqual(["/linux.md", "/browser", false]);
  });
});

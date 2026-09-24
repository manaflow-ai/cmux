import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

// Model a Hexclave outage: its client throws the failed session fetch during
// render, even for `useUser({ or: "return-null" })`.
const hexclaveOutage = new Error("Failed to fetch: api.hexclave.com unreachable");
mock.module("@hexclave/next", () => ({
  StackClientApp: class {},
  StackProvider: () => {
    throw hexclaveOutage;
  },
  useUser: () => {
    throw hexclaveOutage;
  },
}));
mock.module("next/navigation", () => ({
  usePathname: () => "/",
  useSearchParams: () => new URLSearchParams(),
}));

describe("landing providers during a Hexclave outage", () => {
  test("render the page instead of throwing the auth failure", async () => {
    process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "test-project";
    process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-key";
    const { Providers } = await import("../app/[locale]/providers");

    const html = renderToStaticMarkup(
      <Providers>
        <main>cmux landing content</main>
      </Providers>,
    );

    expect(html).toContain("cmux landing content");
  });
});

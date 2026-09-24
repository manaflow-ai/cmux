import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

// Model a Hexclave outage: its client throws the failed session fetch during
// render, even for `useUser({ or: "return-null" })`.
const hexclaveOutage = new Error("Failed to fetch: api.hexclave.com unreachable");
mock.module("@hexclave/next", () => ({
  StackClientApp: class {},
  StackProvider: ({ children }: React.PropsWithChildren) => children,
  useUser: () => {
    throw hexclaveOutage;
  },
}));
mock.module("next/navigation", () => ({
  usePathname: () => "/",
  useSearchParams: () => new URLSearchParams(),
}));

describe("landing providers during a Hexclave outage", () => {
  test("keep Hexclave mounted and still render the page", async () => {
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

  test("the isolated boundary swaps only its own subtree for the fallback", async () => {
    const { IsolatedErrorBoundary } = await import("../app/components/error-boundary");
    const boundary = new IsolatedErrorBoundary({
      name: "test",
      fallback: "fallback",
      children: "widget",
    });
    expect(boundary.render()).toBe("widget");
    boundary.state = { ...boundary.state, ...IsolatedErrorBoundary.getDerivedStateFromError() };
    expect(boundary.render()).toBe("fallback");
  });
});

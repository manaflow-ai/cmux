import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

// Model a Hexclave outage: its client throws the failed session fetch during
// render, even for `useUser({ or: "return-null" })`.
const hexclaveOutage = new Error("Failed to fetch: api.hexclave.com unreachable");
let stackProviderRenders = 0;
mock.module("@hexclave/next", () => ({
  StackClientApp: class {},
  StackProvider: ({ children }: React.PropsWithChildren) => {
    stackProviderRenders += 1;
    return children;
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
  test("marketing pages render without mounting Hexclave", async () => {
    process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "test-project";
    process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-key";
    const { Providers } = await import("../app/[locale]/providers");

    stackProviderRenders = 0;
    const html = renderToStaticMarkup(
      <Providers>
        <main>cmux landing content</main>
      </Providers>,
    );

    expect(html).toContain("cmux landing content");
    expect(stackProviderRenders).toBe(0);
  });

  test("the dashboard keeps Hexclave mounted and still renders", async () => {
    process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "test-project";
    process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-key";
    const { StackProviders } = await import("../app/[locale]/stack-providers");

    stackProviderRenders = 0;
    const html = renderToStaticMarkup(
      <StackProviders>
        <main>cmux dashboard content</main>
      </StackProviders>,
    );

    expect(html).toContain("cmux dashboard content");
    expect(stackProviderRenders).toBe(1);
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

    // Re-rendering with the same element keeps the fallback; a new element
    // from the parent retries the widget.
    expect(IsolatedErrorBoundary.getDerivedStateFromProps(boundary.props, boundary.state)).toEqual({});
    expect(
      IsolatedErrorBoundary.getDerivedStateFromProps({ ...boundary.props, children: "widget again" }, boundary.state),
    ).toEqual({ failed: false, children: "widget again" });
  });
});

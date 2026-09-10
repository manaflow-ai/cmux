import { AsyncLocalStorage } from "node:async_hooks";
import { describe, expect, mock, test } from "bun:test";

// Use the same React Server Components build that Next uses. Bun's default
// React condition makes cache() a no-op and would give false test confidence.
const reactServer = await import(
  // @ts-expect-error Next's internal React Server Components build has no public types.
  "next/dist/compiled/react-experimental/react.react-server.js",
);
mock.module("react", () => reactServer);
const React = await import("react");
const { renderToReadableStream } = await import(
  // @ts-expect-error Next's internal React Server Components renderer has no public types.
  "next/dist/compiled/react-server-dom-turbopack/server.node",
);

const requestIdentity = new AsyncLocalStorage<{ readonly id: string }>();
const getUser = mock(async () => ({
  id: requestIdentity.getStore()?.id ?? "missing-request-context",
}));

mock.module("@stackframe/stack", () => ({
  StackServerApp: class {
    getUser = getUser;
  },
}));
mock.module("../app/env", () => ({
  env: {
    NEXT_PUBLIC_STACK_PROJECT_ID: "project-id",
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: "publishable-key",
    STACK_SECRET_SERVER_KEY: "secret-key",
  },
}));
mock.module("../services/auth/stackApiBaseURL", () => ({
  stackApiBaseURL: () => "https://stack.test",
}));
mock.module("../db/client", () => ({ cloudDb: () => ({}) }));
mock.module("../services/account/metadataMutation", () => ({
  withFreshAccountMetadataUser: async () => undefined,
}));
mock.module("../services/billing/emailMatching", () => ({
  canonicalizeEmailForMatching: (email: string) => email,
}));
mock.module("../services/auth/stackTelemetry", () => ({
  withStackAuthSpan: async <T>(
    _operation: string,
    fn: (span: unknown) => Promise<T>,
  ) => fn({ setAttribute: () => undefined }),
}));

const { getRequestScopedStackUser } = await import("../app/lib/stack");

async function renderForIdentity(id: string): Promise<string> {
  return requestIdentity.run({ id }, async () => {
    async function Probe() {
      const first = getRequestScopedStackUser("dashboard");
      const second = getRequestScopedStackUser("admin_page");
      const [firstUser, secondUser] = await Promise.all([first, second]);
      return React.createElement("p", null, `${firstUser?.id}:${secondUser?.id}`);
    }

    const stream = await renderToReadableStream(React.createElement(Probe), {});
    return new Response(stream).text();
  });
}

describe("request-scoped Stack user cache", () => {
  test("deduplicates one render without sharing identity across concurrent renders", async () => {
    getUser.mockClear();

    const [alice, bob] = await Promise.all([
      renderForIdentity("alice"),
      renderForIdentity("bob"),
    ]);

    expect(alice).toContain("alice:alice");
    expect(bob).toContain("bob:bob");
    expect(getUser).toHaveBeenCalledTimes(2);
  });
});

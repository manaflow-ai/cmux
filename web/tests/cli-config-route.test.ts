import { describe, expect, test } from "bun:test";
import { GET } from "../app/api/cli/config/route";

type CliConfigEnvKey =
  | "NEXT_PUBLIC_STACK_API_URL"
  | "NEXT_PUBLIC_STACK_PROJECT_ID"
  | "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY"
  | "SUBROUTER_HOSTED_URL"
  | "VERCEL_ENV";

const testEnvironment = {
  NEXT_PUBLIC_STACK_API_URL: "https://stack.example.test/api/v1",
  NEXT_PUBLIC_STACK_PROJECT_ID: "test-stack-project-id",
  NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: "test-stack-publishable-key",
  SUBROUTER_HOSTED_URL: "https://subrouter.example.test",
  VERCEL_ENV: "preview",
} satisfies Record<CliConfigEnvKey, string>;

async function withCliConfigEnvironment(
  overrides: Partial<Record<CliConfigEnvKey, string | undefined>>,
  run: () => Promise<void>,
): Promise<void> {
  const entries = Object.entries(overrides) as Array<
    [CliConfigEnvKey, string | undefined]
  >;
  const originalValues = new Map(
    entries.map(([key]) => [key, process.env[key]]),
  );

  try {
    for (const [key, value] of entries) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
    await run();
  } finally {
    for (const [key, value] of originalValues) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
  }
}

describe("CLI config route", () => {
  test("uses cmux.com for production CodeRouter browser auth and preserves the login code", async () => {
    await withCliConfigEnvironment(testEnvironment, async () => {
      const response = GET(
        new Request("https://coderouter.dev/api/cli/config"),
      );

      expect(response.status).toBe(200);
      const body = await response.json();
      expect(body.auth.confirmUrl).toBe(
        "https://cmux.com/handler/cli-auth-confirm",
      );
      expect(body.coderouter.sessionUrl).toBe(
        "https://coderouter.dev/api/coderouter/session",
      );
      expect(body.coderouter.openaiBaseUrl).toBe("https://coderouter.dev/v1");

      const nonDefaultPortResponse = GET(
        new Request("https://coderouter.dev:4443/api/cli/config"),
      );
      const nonDefaultPortBody = await nonDefaultPortResponse.json();
      expect(nonDefaultPortBody.auth.confirmUrl).toBe(
        "https://cmux.com/handler/cli-auth-confirm",
      );
      expect(nonDefaultPortBody.coderouter.sessionUrl).toBe(
        "https://coderouter.dev:4443/api/coderouter/session",
      );

      const confirmation = new URL(body.auth.confirmUrl);
      confirmation.searchParams.set("login_code", "fresh-test-login-code");
      const signIn = new URL("https://cmux.com/handler/sign-in");
      signIn.searchParams.set(
        "after_auth_return_to",
        `${confirmation.pathname}${confirmation.search}`,
      );
      expect(signIn.toString()).toBe(
        "https://cmux.com/handler/sign-in?after_auth_return_to=%2Fhandler%2Fcli-auth-confirm%3Flogin_code%3Dfresh-test-login-code",
      );
    });
  });

  test("publishes CodeRouter and the hosted Subrouter POST contract", async () => {
    await withCliConfigEnvironment(testEnvironment, async () => {
      const response = GET(new Request("https://cmux.com/api/cli/config"));
      expect(response.status).toBe(200);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(await response.json()).toEqual({
        version: 4,
        clientContract: {
          protocolVersion: 4,
          minCliVersion: "0.2.3",
          requiredFeatures: ["coderouter", "organizations"],
        },
        auth: {
          apiUrl: testEnvironment.NEXT_PUBLIC_STACK_API_URL,
          projectId: testEnvironment.NEXT_PUBLIC_STACK_PROJECT_ID,
          publishableClientKey:
            testEnvironment.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
          confirmUrl: "https://cmux.com/handler/cli-auth-confirm",
        },
        coderouter: {
          sessionUrl: "https://cmux.com/api/coderouter/session",
          accountsUrl: "https://cmux.com/api/coderouter/accounts",
          organizationsUrl:
            "https://cmux.com/api/coderouter/organizations",
          openaiBaseUrl: "https://cmux.com/v1",
        },
        subrouter: {
          url: testEnvironment.SUBROUTER_HOSTED_URL,
          exchangeUrl: "https://cmux.com/api/subrouter/tenant-exchange",
        },
      });
    });
  });

  test("keeps compatibility metadata additive for older clients", async () => {
    await withCliConfigEnvironment(testEnvironment, async () => {
      const response = GET(
        new Request("https://cmux.com/api/cli/config?clientVersion=0.2.2", {
          headers: {
            "user-agent": "coderouter/0.2.2",
          },
        }),
      );

      expect(response.status).toBe(200);
      const body = await response.json();
      expect(body.clientContract).toEqual({
        protocolVersion: 4,
        minCliVersion: "0.2.3",
        requiredFeatures: ["coderouter", "organizations"],
      });
      expect(Object.keys(body.clientContract).sort()).toEqual([
        "minCliVersion",
        "protocolVersion",
        "requiredFeatures",
      ]);
      expect(body).toHaveProperty("version", 4);
      expect(body).toHaveProperty("auth");
      expect(body).toHaveProperty("coderouter");
      expect(body).toHaveProperty("subrouter");
    });
  });

  test("keeps CLI approval on the origin that issued the Stack login code", async () => {
    await withCliConfigEnvironment(testEnvironment, async () => {
      const response = GET(
        new Request("http://127.0.0.1:4152/api/cli/config"),
      );

      expect(response.status).toBe(200);
      const body = await response.json();
      expect(body.auth.confirmUrl).toBe(
        "http://127.0.0.1:4152/handler/cli-auth-confirm",
      );
      expect(body.coderouter.sessionUrl).toBe(
        "http://127.0.0.1:4152/api/coderouter/session",
      );
    });
  });

  test("keeps confirmation on a custom staging origin", async () => {
    await withCliConfigEnvironment(testEnvironment, async () => {
      const response = GET(
        new Request("https://coderouter-staging.example.test/api/cli/config"),
      );

      expect(response.status).toBe(200);
      const body = await response.json();
      expect(body.auth.confirmUrl).toBe(
        "https://coderouter-staging.example.test/handler/cli-auth-confirm",
      );
      expect(body.coderouter.sessionUrl).toBe(
        "https://coderouter-staging.example.test/api/coderouter/session",
      );
    });
  });

  test("returns 503 instead of advertising incomplete Stack configuration", async () => {
    await withCliConfigEnvironment(
      {
        ...testEnvironment,
        NEXT_PUBLIC_STACK_PROJECT_ID: undefined,
        NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: undefined,
      },
      async () => {
        const response = GET(new Request("https://cmux.com/api/cli/config"));
        expect(response.status).toBe(503);
        expect(await response.json()).toEqual({
          error: "cli_auth_unavailable",
        });
      },
    );
  });

});

import { describe, expect, test } from "bun:test";
import { GET } from "../app/api/cli/config/route";

type CliConfigEnvKey =
  | "NEXT_PUBLIC_STACK_PROJECT_ID"
  | "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY"
  | "SUBROUTER_HOSTED_URL"
  | "VERCEL_ENV";

const testEnvironment = {
  NEXT_PUBLIC_STACK_PROJECT_ID: "test-stack-project-id",
  NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: "test-stack-publishable-key",
  SUBROUTER_HOSTED_URL: "https://subrouter.example.test",
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
  test("publishes native Stack Auth and hosted Subrouter configuration", async () => {
    await withCliConfigEnvironment(testEnvironment, async () => {
      const response = GET(new Request("https://cmux.com/api/cli/config"));
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({
        version: 1,
        auth: {
          apiUrl: "https://api.stack-auth.com/api/v1",
          projectId: testEnvironment.NEXT_PUBLIC_STACK_PROJECT_ID,
          publishableClientKey:
            testEnvironment.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
          confirmUrl: "https://cmux.com/handler/cli-auth-confirm",
        },
        subrouter: {
          url: testEnvironment.SUBROUTER_HOSTED_URL,
        },
      });
    });
  });

  test("keeps CLI approval on the origin that issued the Stack login code", async () => {
    await withCliConfigEnvironment(testEnvironment, async () => {
      const response = GET(
        new Request("http://127.0.0.1:4152/api/cli/config"),
      );

      expect(response.status).toBe(200);
      expect((await response.json()).auth.confirmUrl).toBe(
        "http://127.0.0.1:4152/handler/cli-auth-confirm",
      );
    });
  });

  test("defaults non-production deployments to staging Subrouter", async () => {
    for (const deploymentEnvironment of [undefined, "development", "preview"]) {
      await withCliConfigEnvironment(
        {
          ...testEnvironment,
          SUBROUTER_HOSTED_URL: undefined,
          VERCEL_ENV: deploymentEnvironment,
        },
        async () => {
          const response = GET(new Request("https://preview.example/api/cli/config"));
          expect(response.status).toBe(200);
          expect((await response.json()).subrouter.url).toBe(
            "https://staging.sr.cmux.com",
          );
        },
      );
    }
  });

  test("defaults production deployments to production Subrouter", async () => {
    await withCliConfigEnvironment(
      {
        ...testEnvironment,
        SUBROUTER_HOSTED_URL: undefined,
        VERCEL_ENV: "production",
      },
      async () => {
        const response = GET(new Request("https://cmux.com/api/cli/config"));
        expect(response.status).toBe(200);
        expect((await response.json()).subrouter.url).toBe(
          "https://sr.cmux.com",
        );
      },
    );
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

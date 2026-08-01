import { describe, expect, test } from "bun:test";
import { GET } from "../app/api/cli/config/route";

describe("CLI config route", () => {
  test("publishes native Stack Auth and hosted Subrouter configuration", async () => {
    const response = GET();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      version: 1,
      auth: {
        apiUrl: "https://api.stack-auth.com/api/v1",
        projectId: process.env.NEXT_PUBLIC_STACK_PROJECT_ID,
        publishableClientKey: process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
        confirmUrl: "https://cmux.com/handler/cli-auth-confirm",
      },
      subrouter: {
        url: "https://sr.cmux.com",
      },
    });
  });

  test("returns 503 instead of advertising incomplete Stack configuration", async () => {
    const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
    const publishableKey = process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;
    delete process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
    delete process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;
    try {
      const response = GET();
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({
        error: "cli_auth_unavailable",
      });
    } finally {
      if (projectId === undefined) {
        delete process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
      } else {
        process.env.NEXT_PUBLIC_STACK_PROJECT_ID = projectId;
      }
      if (publishableKey === undefined) {
        delete process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;
      } else {
        process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = publishableKey;
      }
    }
  });
});

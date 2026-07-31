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
        url: "https://sr.cmux.dev",
      },
    });
  });
});

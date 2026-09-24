import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";
import {
  TEST_STACK_PROJECT_ID,
  TEST_STACK_REFRESH_COOKIE,
} from "./helpers/dashboard-session-mock";

const previousProjectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;

describe("dashboard session middleware", () => {
  beforeAll(() => {
    process.env.NEXT_PUBLIC_STACK_PROJECT_ID = TEST_STACK_PROJECT_ID;
  });
  afterAll(() => {
    if (previousProjectId === undefined) {
      delete process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
    } else {
      process.env.NEXT_PUBLIC_STACK_PROJECT_ID = previousProjectId;
    }
  });

  test("redirects a dashboard request without a Stack session cookie to sign-in", () => {
    const response = middleware(
      new NextRequest("https://cmux.com/ja/dashboard/coderouter?team=team-1", {
        headers: { host: "cmux.com" },
      }),
    );

    expect(response.status).toBe(307);
    const location = new URL(response.headers.get("location") ?? "");
    expect(location.pathname).toBe("/handler/sign-in");
    const afterSignIn = new URL(
      location.searchParams.get("after_auth_return_to") ?? "",
      "https://cmux.com",
    );
    expect(afterSignIn.searchParams.get("after_auth_return_to")).toBe(
      "/ja/dashboard/coderouter?team=team-1",
    );
  });

  test("lets a request with the session cookie reach the dashboard", () => {
    const response = middleware(
      new NextRequest("https://cmux.com/ja/dashboard/cloud", {
        headers: {
          host: "cmux.com",
          cookie: `__Host-hexclave-refresh-${TEST_STACK_PROJECT_ID}--abc=refresh-1`,
        },
      }),
    );

    expect(response.status).not.toBe(307);
    expect(response.headers.get("location")).toBeNull();
    expect(
      response.headers.get("x-middleware-request-x-cmux-dashboard-return-path"),
    ).toBe("/dashboard/cloud");
  });

  test("ignores the cookie gate outside the dashboard", () => {
    const response = middleware(
      new NextRequest("https://cmux.com/pricing", {
        headers: { host: "cmux.com" },
      }),
    );

    expect(response.status).not.toBe(307);
  });
});

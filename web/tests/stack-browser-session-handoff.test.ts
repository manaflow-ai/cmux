import { describe, expect, mock, test } from "bun:test";
import type { StackServerApp } from "@stackframe/stack";
import { NextRequest, NextResponse } from "next/server";

import { createStackBrowserSessionHandoffAdapter } from
  "../services/auth/stackBrowserSessionHandoff";

describe("Stack browser session handoff adapter", () => {
  test("validates a complete SDK token store and emits the browser cookie contract", async () => {
    const getTokens = mock(async () => ({
      accessToken: "validated-access",
      refreshToken: "validated-refresh",
    }));
    const getUser = mock(async () => ({ currentSession: { getTokens } }));
    const adapter = createStackBrowserSessionHandoffAdapter(
      { getUser } as unknown as StackServerApp<true>,
      "12345678-1234-4123-8123-123456789abc",
    );
    const request = new NextRequest(
      "https://cmux.test/handler/app-session-handoff",
      { method: "POST" },
    );
    const response = new NextResponse(null, { status: 204 });

    await expect(adapter.establish({
      request,
      response,
      tokens: {
        accessToken: "native-access",
        refreshToken: "native-refresh",
      },
      now: 1_721_955_600_000,
    })).resolves.toBe(true);

    expect(getUser).toHaveBeenCalledWith({
      tokenStore: {
        accessToken: "native-access",
        refreshToken: "native-refresh",
      },
    });
    const setCookie = response.headers.get("set-cookie") ?? "";
    expect(setCookie).toContain("hexclave-access=");
    expect(setCookie).toContain(
      "__Host-hexclave-refresh-12345678-1234-4123-8123-123456789abc--default=",
    );
    expect(setCookie.toLowerCase()).not.toContain("httponly");
  });
});

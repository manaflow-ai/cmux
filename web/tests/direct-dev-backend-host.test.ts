import { describe, expect, test } from "bun:test";
import type { NextRequest } from "next/server";
import { directDevBackendHost } from "../app/lib/direct-dev-backend-origin";
import { requestOrigin } from "../app/lib/request-origin";

function request(origin: string): NextRequest {
  return { nextUrl: { origin } } as unknown as NextRequest;
}

describe("direct dev backend host forwarding", () => {
  test("uses the configured Tailscale origin for direct transport", () => {
    expect(
      requestOrigin(request("https://0.0.0.0:3916"), {
        CMUX_DEV_BACKEND_TRANSPORT: "direct",
        CMUX_DEV_BACKEND_TAILSCALE_HOST: "cmux-dev-backend-1.tail137216.ts.net",
        CMUX_WWW_ORIGIN: "https://cmux-dev-backend-1.tail137216.ts.net:3916/",
      }),
    ).toBe("https://cmux-dev-backend-1.tail137216.ts.net:3916");
  });

  test("normalizes direct transport values before selecting the configured origin", () => {
    expect(
      requestOrigin(request("https://0.0.0.0:3916"), {
        CMUX_DEV_BACKEND_TRANSPORT: "  DIRECT ",
        CMUX_DEV_BACKEND_TAILSCALE_HOST: "cmux-dev-backend-1.tail137216.ts.net",
        CMUX_WWW_ORIGIN: "https://cmux-dev-backend-1.tail137216.ts.net:3916/",
      }),
    ).toBe("https://cmux-dev-backend-1.tail137216.ts.net:3916");
  });

  test("accepts the configured origin when it matches the trusted Tailscale host", () => {
    expect(
      requestOrigin(request("https://0.0.0.0:3916"), {
        CMUX_DEV_BACKEND_TRANSPORT: "direct",
        CMUX_DEV_BACKEND_TAILSCALE_HOST: " CMUX-Dev-Backend-1.tail137216.ts.net ",
        CMUX_WWW_ORIGIN: "https://cmux-dev-backend-1.tail137216.ts.net:3916/",
      }),
    ).toBe("https://cmux-dev-backend-1.tail137216.ts.net:3916");
  });

  test("fails closed when no trusted Tailscale host is declared", () => {
    expect(
      requestOrigin(request("https://0.0.0.0:3916"), {
        CMUX_DEV_BACKEND_TRANSPORT: "direct",
        CMUX_WWW_ORIGIN: "https://cmux-dev-backend-1.tail137216.ts.net:3916/",
      }),
    ).toBe("https://0.0.0.0:3916");
    expect(
      requestOrigin(request("https://0.0.0.0:3916"), {
        CMUX_DEV_BACKEND_TRANSPORT: "direct",
        CMUX_DEV_BACKEND_TAILSCALE_HOST: "   ",
        CMUX_WWW_ORIGIN: "https://cmux-dev-backend-1.tail137216.ts.net:3916/",
      }),
    ).toBe("https://0.0.0.0:3916");
  });

  test("rejects a configured origin on a different host than the trusted one", () => {
    expect(
      requestOrigin(request("https://0.0.0.0:3916"), {
        CMUX_DEV_BACKEND_TRANSPORT: "direct",
        CMUX_DEV_BACKEND_TAILSCALE_HOST: "cmux-dev-backend-1.tail137216.ts.net",
        CMUX_WWW_ORIGIN: "https://other-node.tail137216.ts.net:3916/",
      }),
    ).toBe("https://0.0.0.0:3916");
  });

  test("keeps the Next origin for the SSH transport", () => {
    expect(
      requestOrigin(request("http://127.0.0.1:3916"), {
        CMUX_DEV_BACKEND_TRANSPORT: "ssh",
      }),
    ).toBe("http://127.0.0.1:3916");
  });

  test("rejects a malformed configured origin", () => {
    expect(
      requestOrigin(request("http://127.0.0.1:3916"), {
        CMUX_DEV_BACKEND_TRANSPORT: "direct",
        CMUX_DEV_BACKEND_TAILSCALE_HOST: "other.example",
        CMUX_WWW_ORIGIN: "https://other.example:3916/",
      }),
    ).toBe("http://127.0.0.1:3916");
  });

  test("returns the hostname for Next.js dev-resource allowlisting", () => {
    expect(
      directDevBackendHost({
        CMUX_DEV_BACKEND_TRANSPORT: "direct",
        CMUX_DEV_BACKEND_TAILSCALE_HOST: "cmux-dev-backend-1.tail137216.ts.net",
        CMUX_WWW_ORIGIN: "https://cmux-dev-backend-1.tail137216.ts.net:3916/",
      }),
    ).toBe("cmux-dev-backend-1.tail137216.ts.net");
  });
});

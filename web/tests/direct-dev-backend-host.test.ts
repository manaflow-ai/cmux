import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import { directDevBackendHost } from "../app/lib/direct-dev-backend-origin";
import { requestOrigin } from "../app/lib/request-origin";
import middleware from "../proxy";

function withDirectOrigin(run: () => void) {
  const values = {
    CMUX_DEV_BACKEND_TRANSPORT: "direct",
    CMUX_DEV_BACKEND_TAILSCALE_HOST: "cmux-dev-backend-1.tail137216.ts.net",
    CMUX_WWW_ORIGIN: "https://cmux-dev-backend-1.tail137216.ts.net:3916/",
  };
  const previous = Object.fromEntries(Object.keys(values).map((key) => [key, process.env[key]]));
  Object.assign(process.env, values);
  try { run(); } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

function request(origin: string): NextRequest {
  return { nextUrl: { origin } } as unknown as NextRequest;
}

describe("direct dev backend host forwarding", () => {
  test("keeps page rewrites inside the server instead of sending them through middleware again", () => {
    withDirectOrigin(() => {
      for (const pathname of ["/", "/billing/success?session_id=test"]) {
        const response = middleware(new NextRequest(`http://0.0.0.0:3916${pathname}`));
        expect(response.status).toBe(200);
        expect(response.headers.get("location")).toBeNull();
        const rewritten = new URL(response.headers.get("x-middleware-rewrite")!);
        expect(rewritten.origin).toBe("http://0.0.0.0:3916");
        expect(rewritten.pathname.startsWith("/en")).toBe(true);
      }
    });
  });

  test("keeps browser redirects on the public HTTPS origin", () => {
    withDirectOrigin(() => {
      const response = middleware(new NextRequest("http://0.0.0.0:3916/en"));
      expect(response.status).toBe(307);
      expect(response.headers.get("location")).toBe("https://cmux-dev-backend-1.tail137216.ts.net:3916/");
    });
  });

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

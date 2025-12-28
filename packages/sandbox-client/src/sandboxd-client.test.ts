import { describe, expect, it } from "vitest";
import { SandboxdClient, SandboxdClientError } from "./sandboxd-client.js";

describe("SandboxdClient", () => {
  it("should construct with base URL", () => {
    const client = new SandboxdClient("http://localhost:46831");
    expect(client).toBeInstanceOf(SandboxdClient);
  });

  it("should strip trailing slash from base URL", () => {
    const client = new SandboxdClient("http://localhost:46831/");
    const url = client.getSubdomainUrl(1, 39378);
    expect(url).toBe("http://1-39378.localhost:46831");
  });

  it("should generate correct subdomain URL", () => {
    const client = new SandboxdClient("http://localhost:46831");
    expect(client.getSubdomainUrl(0, 39378)).toBe("http://0-39378.localhost:46831");
    expect(client.getSubdomainUrl(5, 5910)).toBe("http://5-5910.localhost:46831");
  });
});

describe("SandboxdClientError", () => {
  it("should include status code and body", () => {
    const error = new SandboxdClientError("Request failed", 404, "Not found");
    expect(error.message).toBe("Request failed");
    expect(error.statusCode).toBe(404);
    expect(error.body).toBe("Not found");
    expect(error.name).toBe("SandboxdClientError");
  });
});

import { afterEach, describe, expect, test } from "bun:test";
import http from "node:http";
import type { AddressInfo } from "node:net";
import {
  createPinnedProviderFetch,
  UnsafeProviderAddressError,
} from "../services/coderouter/pinnedProviderFetch";
import { __test } from "../services/coderouter/opencodeProxy";

type Hit = { readonly method: string; readonly url: string; readonly body: string };

const servers: http.Server[] = [];
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))));
});

async function server(handler: (hit: Hit, response: http.ServerResponse) => void): Promise<{ port: number; hits: Hit[] }> {
  const hits: Hit[] = [];
  const instance = http.createServer((request, response) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => {
      const hit = { method: request.method ?? "", url: request.url ?? "", body: Buffer.concat(chunks).toString() };
      hits.push(hit);
      handler(hit, response);
    });
  });
  servers.push(instance);
  await new Promise<void>((resolve) => instance.listen(0, "127.0.0.1", resolve));
  return { port: (instance.address() as AddressInfo).port, hits };
}

/** A resolver whose answer is fixed per test, standing in for attacker DNS. */
function resolvesTo(address: string, calls: string[] = []) {
  return ((hostname: string, _options: unknown, callback: (error: null, addresses: { address: string; family: number }[]) => void) => {
    calls.push(hostname);
    callback(null, [{ address, family: 4 }]);
  });
}

describe("pinned provider fetch", () => {
  test("refuses to connect when the connection-time lookup answers a private address", async () => {
    // DNS rebinding: the preflight saw a public answer, the connection sees
    // loopback. The connection must fail before any byte reaches the target.
    const target = await server((_hit, response) => response.end("internal"));
    const calls: string[] = [];
    const providerFetch = createPinnedProviderFetch({
      isUnsafeAddress: __test.unsafeProviderAddress,
      lookup: resolvesTo("127.0.0.1", calls),
      request: http.request as never,
      agent: false,
    });
    const attempt = providerFetch(new URL(`http://provider.example:${target.port}/v1/chat`), {
      method: "POST",
      headers: { authorization: "Bearer opencode-secret" },
      body: "{}",
    });
    await expect(attempt).rejects.toBeInstanceOf(UnsafeProviderAddressError);
    expect(calls).toEqual(["provider.example"]);
    expect(target.hits).toEqual([]);
  });

  test("connects to the vetted answer and returns a redirect without following it", async () => {
    const target = await server((hit, response) => {
      if (hit.url === "/v1/chat") {
        response.writeHead(307, { location: "/internal/secret" });
        response.end();
        return;
      }
      response.end("internal");
    });
    const providerFetch = createPinnedProviderFetch({
      // Loopback stands in for a public provider address in this test.
      isUnsafeAddress: () => false,
      lookup: resolvesTo("127.0.0.1"),
      request: http.request as never,
      agent: false,
    });
    const response = await providerFetch(new URL(`http://provider.example:${target.port}/v1/chat`), {
      method: "POST",
      body: "{}",
    });
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("/internal/secret");
    expect(target.hits.map((hit) => hit.url)).toEqual(["/v1/chat"]);
  });

  test("streams the request body and response body through the pinned connection", async () => {
    const target = await server((hit, response) => {
      response.writeHead(200, { "content-type": "text/plain" });
      response.end(`echo:${hit.body}`);
    });
    const providerFetch = createPinnedProviderFetch({
      isUnsafeAddress: () => false,
      lookup: resolvesTo("127.0.0.1"),
      request: http.request as never,
      agent: false,
    });
    const body = new Request("https://unused.example", { method: "POST", body: "hello" }).body;
    const response = await providerFetch(new URL(`http://provider.example:${target.port}/v1/chat`), {
      method: "POST",
      body,
      duplex: "half",
    } as RequestInit);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/plain");
    await expect(response.text()).resolves.toBe("echo:hello");
  });
});

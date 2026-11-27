import { afterAll, describe, expect, test } from "bun:test";
import { serverReceived, startFixtureServer } from "./fixtures.mjs";

const server = startFixtureServer();
afterAll(() => server.stop());

describe("fixture site", () => {
  test("serves the order page with its total", async () => {
    const html = await (await fetch(`${server.url}/order`)).text();
    expect(html).toContain("$1,284.50");
  });
  test("records a sign-up post and grades it", async () => {
    const body = new URLSearchParams({ name: "Ada Lovelace", plan: "pro" });
    const res = await fetch(`${server.url}/signup`, { method: "POST", body });
    expect(res.status).toBe(200);
    expect(serverReceived(server.posts, { path: "/signup", body: { name: "ada lovelace", plan: "Pro" } })).toBe(true);
    expect(serverReceived(server.posts, { path: "/signup", body: { name: "Ada Lovelace", plan: "team" } })).toBe(false);
  });
  test("a second post to the same form fails the exactly-once rule", () => {
    const posts = [
      { path: "/signup", body: { name: "Ada Lovelace", plan: "pro" } },
      { path: "/signup", body: { name: "Ada Lovelace", plan: "pro" } },
    ];
    expect(serverReceived(posts, { path: "/signup", body: { name: "Ada Lovelace", plan: "pro" } })).toBe(false);
  });
});

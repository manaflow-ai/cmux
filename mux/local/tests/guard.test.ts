import { expect, test } from "bun:test";
import { hostAllowed, originAllowed } from "../src/guard.ts";

const req = (headers: Record<string, string>) =>
  new Request("http://127.0.0.1:47820/api/me", { headers });

test("only loopback hosts for this port reach the server", () => {
  expect(hostAllowed(req({ host: "127.0.0.1:47820" }), 47820)).toBe(true);
  expect(hostAllowed(req({ host: "localhost:47820" }), 47820)).toBe(true);
  expect(hostAllowed(req({ host: "evil.example:47820" }), 47820)).toBe(false);
  expect(hostAllowed(req({ host: "127.0.0.1:5173" }), 47820)).toBe(false);
});

test("browser requests from other sites are refused; local tools without Origin are allowed", () => {
  expect(originAllowed(req({}), 47820)).toBe(true);
  expect(originAllowed(req({ origin: "http://127.0.0.1:47820" }), 47820)).toBe(true);
  expect(originAllowed(req({ origin: "https://evil.example" }), 47820)).toBe(false);
  expect(originAllowed(req({ origin: "http://localhost:3000" }), 47820)).toBe(false);
});

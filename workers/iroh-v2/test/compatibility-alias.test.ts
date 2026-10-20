import { expect, test } from "bun:test";
import { assertAliasSafe } from "../scripts/check-compatibility-aliases";
import alias from "../aliases/index";

const canonical = { bindings: [
  { name: "TEAM_CONTROL", type: "durable_object_namespace", class_name: "TeamControl" },
  { name: "USER_USAGE", type: "durable_object_namespace", class_name: "UserUsage" },
] };
const forwarding = { bindings: [{ name: "CANONICAL", type: "service", service: "cmux-v2" }] };

test("alias deployment accepts a renamed backend and rejects overwriting storage", () => {
  expect(() => assertAliasSafe(canonical, null, "cmux-v2")).not.toThrow();
  expect(() => assertAliasSafe(canonical, forwarding, "cmux-v2")).not.toThrow();
  expect(() => assertAliasSafe(canonical, canonical, "cmux-v2")).toThrow("rename it in place");
  expect(() => assertAliasSafe({ bindings: [] }, forwarding, "cmux-v2")).toThrow("storage binding");
  expect(() => assertAliasSafe(canonical, forwarding, "cmux-v2-staging")).toThrow("rename it in place");
});

test("alias preserves the original authorization, body, URL and response", async () => {
  const request = new Request("https://cmux-iroh-v2.debussy.workers.dev/v2/control/session", {
    method: "POST", headers: { authorization: "Bearer test-ticket" }, body: "payload",
  });
  const response = new Response("validation error", { status: 400 });
  const binding = { fetch: async (forwarded: Request) => {
    expect(forwarded).toBe(request);
    expect(forwarded.headers.get("authorization")).toBe("Bearer test-ticket");
    expect(await forwarded.text()).toBe("payload");
    return response;
  } } as unknown as Fetcher;
  expect(await alias.fetch(request, { CANONICAL: binding })).toBe(response);
});

import { expect, test } from "bun:test";
import { StackAuthority } from "../src/auth";
import { descriptor as device } from "./fixtures";

const configuration = {
  environment: device.identity.environment, projectId: device.identity.projectId,
  apiURL: "https://stack.example/", publishableKey: "test-publishable-key",
};

test("Stack establishes user and explicit team authority without a solo-team fallback", async () => {
  const paths: string[] = [];
  const authority = new StackAuthority(configuration, async (url, init) => {
    paths.push(new URL(url).pathname);
    expect(new Headers(init.headers).get("x-stack-access-token")).toBe("test-token");
    return Response.json(url.includes("users/me") ? { id: device.identity.userId } : { items: [{ id: device.identity.teamId }] });
  });
  expect(await authority.verify("test-token", device.identity, 100)).toEqual({
    environment: device.identity.environment, projectId: device.identity.projectId,
    userId: device.identity.userId, teamId: device.identity.teamId, verifiedAt: 100,
  });
  expect(paths).toEqual(["/api/v1/users/me", "/api/v1/teams"]);
  await expect(authority.verify("test-token", { ...device.identity, teamId: device.identity.userId }, 100))
    .rejects.toMatchObject({ code: "team_access_revoked", status: 403 });
});

test("wrong user, environment and project never create claimed authority", async () => {
  let calls = 0;
  const authority = new StackAuthority(configuration, async () => { calls++; return Response.json({ id: "other-user" }); });
  await expect(authority.verify("test-token", { ...device.identity, environment: "other" }, 100)).rejects.toMatchObject({ code: "environment_mismatch" });
  await expect(authority.verify("test-token", { ...device.identity, projectId: "other" }, 100)).rejects.toMatchObject({ code: "environment_mismatch" });
  expect(calls).toBe(0);
  await expect(authority.verify("test-token", device.identity, 100)).rejects.toMatchObject({ code: "identity_mismatch" });
  expect(calls).toBe(1);
});

test("provider failures remain recoverable while explicit rejection is unauthorized", async () => {
  for (const status of [429, 500, 502, 503]) {
    const authority = new StackAuthority(configuration, async () => new Response("private upstream detail", { status }));
    await expect(authority.verify("test-token", device.identity, 100))
      .rejects.toMatchObject({ code: "upstream_unavailable", status: 503, retryable: true });
  }
  const rejected = new StackAuthority(configuration, async () => new Response(null, { status: 401 }));
  await expect(rejected.verify("test-token", device.identity, 100)).rejects.toMatchObject({ code: "unauthorized", status: 401 });
  const malformed = new StackAuthority(configuration, async () => Response.json({ private: "unexpected provider shape" }));
  await expect(malformed.verify("test-token", device.identity, 100)).rejects.toMatchObject({ code: "upstream_unavailable", retryable: true });
});

test("unverified callers cannot create an unbounded authentication queue", async () => {
  let finish!: (response: Response) => void;
  const pending = new Promise<Response>(resolve => { finish = resolve; });
  const authority = new StackAuthority(configuration, async () => pending, 1);
  const first = authority.verify("first", device.identity, 100);
  await expect(authority.verify("second", device.identity, 100)).rejects.toMatchObject({ code: "upstream_unavailable", status: 503 });
  finish(new Response(null, { status: 401 }));
  await expect(first).rejects.toMatchObject({ code: "unauthorized" });
});

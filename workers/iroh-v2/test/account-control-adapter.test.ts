import { expect, mock, test } from "bun:test";
import { installationKey } from "../src/storage/account-store";

mock.module("cloudflare:workers", () => ({
  DurableObject: class { constructor(readonly ctx: unknown, readonly env: unknown) {} },
}));
const { closesAccountSocket, installationTag } = await import("../src/account-control");

test("socket messages and team notices close an account socket for the same codes", () => {
  for (const code of ["ticket_expired", "device_revoked", "identity_mismatch", "key_replacement_required", "device_not_enrolled", "permission_denied"]) {
    expect({ code, closes: closesAccountSocket(code) }).toEqual({ code, closes: true });
  }
  for (const code of ["rate_limited", "resync_required", "upstream_unavailable", "invalid_request"]) {
    expect({ code, closes: closesAccountSocket(code) }).toEqual({ code, closes: false });
  }
});

test("the installation socket tag stays within the Workers 256-character limit for the longest identity", async () => {
  const key = installationKey({ deviceId: "d".repeat(128), appNamespace: "n".repeat(255), buildTag: "b".repeat(64) });
  const tag = await installationTag(key);
  expect(tag.length).toBeLessThanOrEqual(256);
  expect(tag).toBe(await installationTag(key));
  expect(tag).not.toBe(await installationTag(installationKey({ deviceId: "d", appNamespace: "n", buildTag: "b" })));
});

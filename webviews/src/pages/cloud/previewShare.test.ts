import { describe, expect, test } from "bun:test";
import type { PageClient } from "../shared/pageClient";
import { MockCloudProvider } from "./mockProvider";
import { createPreviewShare, revokePreviewShare } from "./previewShare";

describe("Cloud preview share action", () => {
  test("creates and copies the link, then revokes it", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    const shared = await createPreviewShare(provider, "vm_sample", 3000);
    expect(shared?.linkId).toBe("mock-link-0001");
    expect(shared?.url).toBe("https://preview.example/vm_sample/3000?cmux_share=mock");
    expect(provider.clipboard).toBe(shared?.url);
    const createCall = provider.calls.find(
      (call) => call.params && (call.params as Record<string, unknown>).action === "cloudPreviewShare",
    );
    expect(createCall).toBeDefined();
    expect((createCall!.params as Record<string, unknown>).target).toBe("machine:vm_sample");
    expect(await revokePreviewShare(provider, "vm_sample", 3000, shared!.linkId)).toBe(true);
    expect(provider.previewLinks.size).toBe(0);
  });

  test("unwraps an awaited catalog result and rejects malformed or uncopied responses", async () => {
    const calls: { op: string; params: unknown }[] = [];
    const client: PageClient = {
      async call<R>(op: string, params: unknown): Promise<R> {
        calls.push({ op, params });
        if ((params as { action?: string }).action === "cloudPreviewShare")
          return {
            ran: true,
            result: {
              confirmed: true,
              copied: true,
              machine_id: "vm_sample",
              port: 3000,
              linkId: "nested-link",
              url: "https://preview.example/nested",
              expiresAt: 1_999_999_999_999,
            },
          } as R;
        return { ran: true, result: { confirmed: true, revoked: true } } as R;
      },
      async subscribe() {
        return () => {};
      },
      handle() {
        return () => {};
      },
    };
    const shared = await createPreviewShare(client, "vm_sample", 3000);
    expect(shared?.linkId).toBe("nested-link");
    expect((calls[0].params as Record<string, unknown>).target).toBe("machine:vm_sample");
    expect(await revokePreviewShare(client, "vm_sample", 3000, "nested-link")).toBe(true);

    const malformed: PageClient = {
      ...client,
      call: async <R>() => ({ ran: true, result: { confirmed: true, copied: false } }) as R,
    };
    expect(await createPreviewShare(malformed, "vm_sample", 3000)).toBeUndefined();
  });

  test("treats an already-revoked link as a successful revoke", async () => {
    const client: PageClient = {
      async call<R>(): Promise<R> {
        return { ran: true, result: { confirmed: true, revoked: false } } as R;
      },
      async subscribe() {
        return () => {};
      },
      handle() {
        return () => {};
      },
    };
    expect(await revokePreviewShare(client, "vm_sample", 3000, "gone-link")).toBe(true);
  });
});

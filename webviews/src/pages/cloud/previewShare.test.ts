import { describe, expect, test } from "bun:test";
import { MockCloudProvider } from "./mockProvider";
import { createPreviewShare, revokePreviewShare } from "./previewShare";

describe("Cloud preview share action", () => {
  test("creates and copies the link, then revokes it", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    const shared = await createPreviewShare(provider, "vm_sample", 3000);
    expect(shared?.linkId).toBe("mock-link-0001");
    expect(shared?.url).toBe("https://preview.example/vm_sample/3000?cmux_share=mock");
    expect(provider.clipboard).toBe(shared?.url);
    expect(await revokePreviewShare(provider, "vm_sample", 3000, shared!.linkId)).toBe(true);
    expect(provider.previewLinks.size).toBe(0);
  });
});

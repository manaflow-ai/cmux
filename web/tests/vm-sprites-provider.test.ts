import { describe, expect, test } from "bun:test";
import { SpritesProvider } from "../services/vms/drivers/sprites";
import { providerEnabledEnvKey } from "../services/vms/config";
import { providerImageEnvKey, resolveVmImage } from "../services/vms/images/resolver";

describe("SpritesProvider", () => {
  test("rejects an unpinned bootstrap package before calling Fly", async () => {
    const provider = new SpritesProvider();

    await expect(provider.create({ image: "cmux@latest" })).rejects.toThrow(
      "pinned cmux npm package",
    );
  });

  test("routes interactive attach through Noise enrollment", async () => {
    const provider = new SpritesProvider();

    await expect(provider.openAttach()).rejects.toThrow(
      "cmux-sprites connect",
    );
    await expect(provider.openSSH()).rejects.toThrow(
      "SSH is not exposed",
    );
  });

  test("has explicit create and image configuration", () => {
    expect(providerEnabledEnvKey("sprites")).toBe("CMUX_VM_SPRITES_ENABLED");
    expect(providerImageEnvKey("sprites")).toBe("CMUX_SPRITES_NPM_SPEC");
    expect(resolveVmImage("sprites", undefined, {})).toMatchObject({
      provider: "sprites",
      image: "cmux@0.9.11",
      imageVersion: "sprites-bootstrap-20260805a",
    });
  });
});

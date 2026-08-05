import { describe, expect, test } from "bun:test";
import {
  checkpointMatchingComment,
  mapStatus,
  SpritesProvider,
  waitForServiceStarted,
} from "../services/vms/drivers/sprites";
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

  test("fails closed for unknown Sprite lifecycle states", () => {
    expect(mapStatus("running")).toBe("running");
    expect(() => mapStatus(undefined)).toThrow("unsupported lifecycle status");
    expect(() => mapStatus("future-state")).toThrow("unsupported lifecycle status");
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

  test("waits for the service-owned started event and fails closed", async () => {
    async function* delayedStart() {
      yield { type: "stdout" as const, timestamp: 1, data: "booting" };
      yield { type: "started" as const, timestamp: 2 };
    }
    async function* failedStart() {
      yield { type: "error" as const, timestamp: 1, data: "private provider detail" };
    }

    await expect(waitForServiceStarted(delayedStart())).resolves.toBeUndefined();
    await expect(waitForServiceStarted(failedStart())).rejects.toThrow(
      "cmux service failed during startup",
    );
  });

  test("binds concurrent snapshots to their unique checkpoint comments", async () => {
    const checkpoints = [
      { id: "v1", comment: "cmux-request-a", createTime: new Date(1) },
      { id: "v2", comment: "cmux-request-b", createTime: new Date(2) },
    ];

    const [first, second] = await Promise.all([
      Promise.resolve(checkpointMatchingComment(checkpoints, "cmux-request-a")),
      Promise.resolve(checkpointMatchingComment(checkpoints, "cmux-request-b")),
    ]);

    expect(first?.id).toBe("v1");
    expect(second?.id).toBe("v2");
  });
});

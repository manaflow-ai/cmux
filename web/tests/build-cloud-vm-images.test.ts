import { describe, expect, test } from "bun:test";
import {
  cloudAgentToolPackageSpecs,
  waitForFreestyleSnapshotByName,
  waitForRetryInterval,
} from "../scripts/build-cloud-vm-images";

describe("Cloud VM image build helpers", () => {
  test("disabled tool env values skip the tool install", () => {
    const previous = process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC;
    process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC = "none";
    try {
      expect(cloudAgentToolPackageSpecs().some((tool) => tool.name === "claude")).toBe(false);
    } finally {
      if (previous === undefined) {
        delete process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC;
      } else {
        process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC = previous;
      }
    }
  });

  test("enabled tool specs must be pinned to exact versions", () => {
    const previous = process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC;
    process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC = "@anthropic-ai/claude-code";
    try {
      expect(() => cloudAgentToolPackageSpecs()).toThrow("must be pinned");
    } finally {
      if (previous === undefined) {
        delete process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC;
      } else {
        process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC = previous;
      }
    }
  });

  test("snapshot recovery ignores ready snapshots older than the failed create attempt", async () => {
    const freestyle = {
      fetch: async (_url: string, init?: RequestInit) => {
        expect(init?.signal).toBeInstanceOf(AbortSignal);
        return new Response(JSON.stringify({
          snapshots: [
            {
              snapshotId: "sh-old",
              name: "cmuxd-ws-review",
              state: "ready",
              createdAt: "2026-05-09T04:00:00.000Z",
            },
            {
              snapshotId: "sh-new",
              name: "cmuxd-ws-review",
              state: "ready",
              createdAt: "2026-05-09T05:00:00.000Z",
            },
          ],
        }));
      },
    };

    const recovered = await waitForFreestyleSnapshotByName(
      freestyle as never,
      "cmuxd-ws-review",
      "2026-05-09T04:30:00.000Z",
      100,
    );

    expect(recovered?.snapshotId).toBe("sh-new");
  });

  test("snapshot recovery does not alias only-stale snapshots", async () => {
    const freestyle = {
      fetch: async () =>
        new Response(JSON.stringify({
          snapshots: [
            {
              snapshotId: "sh-stale",
              name: "cmuxd-ws-review",
              state: "ready",
              createdAt: "2026-05-09T04:00:00.000Z",
            },
          ],
        })),
    };

    const recovered = await waitForFreestyleSnapshotByName(
      freestyle as never,
      "cmuxd-ws-review",
      "2026-05-09T04:30:00.000Z",
      10,
    );

    expect(recovered).toBeNull();
  });

  test("retry waits are abortable", async () => {
    const controller = new AbortController();
    const wait = waitForRetryInterval(10_000, controller.signal);
    controller.abort();

    await expect(wait).rejects.toThrow("operation aborted");
  });
});

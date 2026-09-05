import { describe, expect, it } from "bun:test";
import * as Effect from "effect/Effect";

import { handleIrohControlRequest } from "../src/irohHttp";

describe("Iroh HTTP adapter", () => {
  it("does not turn a caller-supplied endpoint header into discovery trust", async () => {
    let trusted = true;
    const backend = {
      broker: {
        discover: (...args: unknown[]) => {
          trusted = args[5] === true;
          return Effect.succeed({ bindings: [] });
        },
      },
    } as never;
    const response = await handleIrohControlRequest(
      new Request("https://worker.test/api/devices/iroh", {
        headers: {
          "x-cmux-app-namespace": "com.cmux.app",
          "x-cmux-control-endpoint-id": "attacker-selected-endpoint",
        },
      }),
      "account-a",
      backend,
    );

    expect(response.response.status).toBe(200);
    expect(trusted).toBe(false);
  });

  it("accepts the explicit in-process DO trust boundary", async () => {
    let trusted = false;
    const backend = {
      broker: {
        discover: (...args: unknown[]) => {
          trusted = args[5] === true;
          return Effect.succeed({ bindings: [] });
        },
      },
    } as never;
    const response = await handleIrohControlRequest(
      new Request("https://worker.test/api/devices/iroh"),
      "account-a",
      backend,
      { accountSessionTrusted: true },
    );

    expect(response.response.status).toBe(200);
    expect(trusted).toBe(true);
  });
});

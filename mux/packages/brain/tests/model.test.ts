import { readFileSync } from "node:fs";
import { expect, test } from "vite-plus/test";
import { collect } from "../src/index.ts";

function streamOf(text: string, chunk = 97): ReadableStream<Uint8Array> {
  const bytes = new TextEncoder().encode(text);
  let offset = 0;
  return new ReadableStream({
    pull(controller) {
      if (offset >= bytes.length) return controller.close();
      controller.enqueue(bytes.slice(offset, offset + chunk));
      offset += chunk;
    },
  });
}

test("a recorded coderouter stream yields its function call, split at any byte boundary", async () => {
  const sse = readFileSync(new URL("./fixtures/function-call.sse", import.meta.url), "utf8");
  for (const chunk of [1, 7, 4096]) {
    const { output } = await collect(streamOf(sse, chunk));
    expect(output).toHaveLength(1);
    expect(output[0]).toMatchObject({ type: "function_call", name: "run" });
    const call = output[0] as { arguments: string };
    expect(JSON.parse(call.arguments)).toEqual({ code: "17 * 23" });
  }
});

test("a failed stream throws", async () => {
  const sse =
    'event: response.failed\ndata: {"type":"response.failed","response":{"error":{"message":"boom"}}}\n\n';
  await expect(collect(streamOf(sse))).rejects.toThrow("boom");
});

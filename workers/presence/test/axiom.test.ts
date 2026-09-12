import { describe, expect, test } from "bun:test";
import { emitAxiomEvent } from "../src/axiom";

describe("emitAxiomEvent", () => {
  test("sends bounded structured events and does not send credentials", async () => {
    let request: Request | undefined;
    await emitAxiomEvent(
      { AXIOM_TOKEN: "token", AXIOM_DATASET: "presence" },
      { event: "do_request", trace_id: "trace-12345678", secret: "x".repeat(400) },
      async (input, init) => {
        request = new Request(input, init);
        return new Response(null, { status: 200 });
      },
    );
    expect(request?.url).toBe("https://api.axiom.co/v1/datasets/presence/ingest");
    expect(request?.headers.get("authorization")).toBe("Bearer token");
    const body = JSON.parse(await request!.text()) as Array<Record<string, unknown>>;
    expect(body).toHaveLength(1);
    expect(body[0]?.event).toBe("do_request");
    expect(String(body[0]?.secret).length).toBe(256);
  });

  test("is a no-op when the dataset is not configured", async () => {
    let called = false;
    await emitAxiomEvent({}, { event: "ignored" }, async () => {
      called = true;
      return new Response();
    });
    expect(called).toBe(false);
  });
});

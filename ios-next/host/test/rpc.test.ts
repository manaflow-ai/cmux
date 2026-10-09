import { describe, expect, it } from "vitest";
import { HostClient } from "../src/client.ts";
import { FrameKind } from "../src/protocol.ts";
import { decodeBrowserFramePayload, encodeBrowserFramePayload, decodeFrame, encodeFrame } from "../src/rpc/frames.ts";
import { RpcServer } from "../src/rpc/server.ts";
import { RpcError } from "../src/rpc/peer.ts";
import { createOpenLoopbackPair } from "../src/transport/loopback.ts";

function setup() {
  const server = new RpcServer(() => ({ hostId: "h1", hostName: "mac", os: "macOS", version: "0", capabilities: ["term.v1"] }));
  const [phone, host] = createOpenLoopbackPair();
  const session = server.attach(host);
  const client = new HostClient(phone);
  return { server, session, client, phone, host };
}

describe("rpc over loopback", () => {
  it("gates everything behind host.hello", async () => {
    const { client } = setup();
    await expect(client.request("host.ping")).rejects.toMatchObject({ code: "unauthorized" });
    const hello = await client.hello();
    expect(hello).toMatchObject({ hostId: "h1", protocol: 1, capabilities: ["term.v1"] });
    const pong = await client.request("host.ping");
    expect(typeof pong.at).toBe("number");
  });

  it("rejects unknown protocol versions and unknown methods", async () => {
    const { client } = setup();
    await expect(client.request("host.hello", { protocol: 99 })).rejects.toMatchObject({ code: "unsupported" });
    await client.hello();
    await expect(client.request("nope.nope")).rejects.toMatchObject({ code: "unsupported" });
  });

  it("maps thrown RpcErrors and plain errors", async () => {
    const { server, client } = setup();
    server.register("x.notfound", () => {
      throw new RpcError("not_found", "missing");
    });
    server.register("x.crash", () => {
      throw new Error("boom");
    });
    await client.hello();
    await expect(client.request("x.notfound")).rejects.toMatchObject({ code: "not_found", message: "missing" });
    await expect(client.request("x.crash")).rejects.toMatchObject({ code: "internal", message: "boom" });
  });

  it("broadcasts events only to helloed clients", async () => {
    const { server, client } = setup();
    const got: unknown[] = [];
    client.peer.on("event", (topic, p) => got.push([topic, p]));
    server.broadcast("a.b", { n: 1 });
    await new Promise((r) => setTimeout(r, 20));
    expect(got).toEqual([]);
    await client.hello();
    server.broadcast("a.b", { n: 2 });
    await new Promise((r) => setTimeout(r, 20));
    expect(got).toEqual([["a.b", { n: 2 }]]);
  });

  it("routes termInput frames to the stream sink and disposes on close", async () => {
    const { session, client, phone } = setup();
    await client.hello();
    const inputs: string[] = [];
    let disposed = false;
    const id = session.addStream({ kind: "term", target: "t", onInput: (d) => inputs.push(Buffer.from(d).toString()), dispose: () => (disposed = true) });
    client.sendInput(id, "ls\r");
    await new Promise((r) => setTimeout(r, 20));
    expect(inputs).toEqual(["ls\r"]);
    phone.close();
    await new Promise((r) => setTimeout(r, 20));
    expect(disposed).toBe(true);
  });

  it("encodes binary frames", () => {
    const f = decodeFrame(encodeFrame(FrameKind.termOutput, 0xdeadbeef, Uint8Array.of(1, 2)))!;
    expect(f).toEqual({ kind: 1, streamId: 0xdeadbeef, payload: Uint8Array.of(1, 2) });
    const p = encodeBrowserFramePayload({ seq: 7, cssW: 390, cssH: 844, pxW: 1170, pxH: 2532, format: 0 }, Uint8Array.of(9));
    expect(decodeBrowserFramePayload(p)).toEqual({ header: { seq: 7, cssW: 390, cssH: 844, pxW: 1170, pxH: 2532, format: 0 }, image: Uint8Array.of(9) });
  });

  it("carries large ctl messages through fragmentation", async () => {
    const { server, client } = setup();
    server.register("x.big", (p) => ({ echo: p.s }));
    await client.hello();
    const s = "x".repeat(300_000);
    expect((await client.request("x.big", { s })).echo).toBe(s);
  });
});

// A reopened chat's sent image keeps its height as it loads (cmuxterm-hq
// docs/design/agent-transcript-clean-slate.md, step 2: "image decode shifts 0 px"). The pane draws
// a sent image's slot before it reads the bytes back (`_acpmux/attachment`) and decodes them; the
// slot's shape is the size the record names (acpmux hub/image_header.rs, read when the image was
// kept), else a square. Over the real client and the mock daemon, which names a kept image's size
// as acpmux does, this measures the slot the reopened chat reserves against the box the decoded
// image draws in, and prints one BENCH line.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window });
});

/// A wide screenshot's PNG header: IHDR of `width` by `height` (the header is all a size read needs).
function pngHeader(width: number, height: number): string {
  const bytes = new Uint8Array(33);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  const view = new DataView(bytes.buffer);
  view.setUint32(16, width);
  view.setUint32(20, height);
  bytes.set([8, 6, 0, 0, 0], 24);
  return Buffer.from(bytes).toString("base64");
}

type Row = { kind: string; images?: { width?: number; height?: number }[] };

test("a reopened chat reserves a sent image's box at its own shape: decoding it shifts nothing", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { sentImageSize } = await import("./conversation/userBubbleModel");
  const natural = { width: 640, height: 160 };
  let socket: InstanceType<typeof MockAcpmuxSocket> | undefined;
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      rows = (next as unknown as { rows: Row[] }).rows;
    },
    undefined,
    () => {
      socket = new MockAcpmuxSocket(() => Promise.resolve());
      return socket as unknown as WebSocket;
    },
  );
  try {
    const answer = (socket as unknown as { answer: (method: string, params: unknown) => Promise<any> }).answer.bind(
      socket,
    );
    // The chat sent a screenshot in an earlier visit: this one knows the image only by its record.
    const { sessionId } = await answer("session/new", { cwd: "/tmp" });
    await answer("session/prompt", {
      sessionId,
      prompt: [
        { type: "text", text: "what is wrong here" },
        { type: "image", mimeType: "image/png", data: pngHeader(natural.width, natural.height) },
      ],
    });
    await client.select(sessionId);
    const image = rows.find((row) => row.kind === "user" && row.images?.length)?.images?.[0];
    expect(image).toBeDefined();
    // The slot drawn before the read, and the box the decoded image draws in (UserBubble.tsx).
    const reserved = sentImageSize(image!);
    const decoded = sentImageSize(natural);
    // The rows below move by the height change; the width change reflows the bubble.
    const shift = Math.abs(reserved.height - decoded.height);
    const reflow = Math.abs(reserved.width - decoded.width);
    console.log(
      `BENCH image-box-reserve natural=${natural.width}x${natural.height} reserved=${reserved.width}x${reserved.height} decoded=${decoded.width}x${decoded.height} heightShiftPx=${shift} widthChangePx=${reflow}`,
    );
    expect(image).toMatchObject(natural);
    expect(shift).toBe(0);
    expect(reflow).toBe(0);
  } finally {
    client.close();
  }
}, 60_000);

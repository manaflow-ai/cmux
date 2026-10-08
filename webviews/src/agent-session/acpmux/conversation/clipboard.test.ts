import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { copyImage } from "./clipboard";

// copyImage draws the image to a canvas and hands the PNG to the clipboard as a promise, which
// WebKit awaits. These stand-ins let each step fail the way WebKit can: a tainted canvas throws in
// drawImage, a canvas too large has no 2D context, an SVG with only a viewBox has no size.
type Step = "ok" | "drawThrows" | "noContext" | "noSize" | "encodeThrows";
let step: Step = "ok";
let written: Promise<Blob> | undefined;

class FakeImage {
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;
  get naturalWidth() {
    return step === "noSize" ? 0 : 40;
  }
  get naturalHeight() {
    return step === "noSize" ? 0 : 30;
  }
  set src(_value: string) {
    queueMicrotask(() => this.onload?.());
  }
}

const canvas = () => ({
  width: 0,
  height: 0,
  getContext: () =>
    step === "noContext"
      ? null
      : {
          drawImage: () => {
            if (step === "drawThrows") throw new Error("SecurityError: the canvas is tainted");
          },
        },
  toBlob: (done: (blob: Blob | null) => void) => {
    if (step === "encodeThrows") throw new Error("SecurityError: the canvas is tainted");
    done(new Blob(["png"], { type: "image/png" }));
  },
});

const globals = globalThis as Record<string, unknown>;
const saved = { Image: globals.Image, ClipboardItem: globals.ClipboardItem, document: globals.document };
const savedNavigator = Object.getOwnPropertyDescriptor(globalThis, "navigator");
globals.Image = FakeImage;
globals.ClipboardItem = class {
  constructor(readonly items: Record<string, Promise<Blob>>) {}
};
globals.document = { createElement: () => canvas() };
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: {
    clipboard: {
      // As WebKit does: the write settles when the item's promise does.
      write: async (items: { items: Record<string, Promise<Blob>> }[]) => {
        written = items[0]!.items["image/png"];
        await written;
      },
    },
  },
});
afterAll(() => {
  Object.assign(globals, saved);
  if (savedNavigator) Object.defineProperty(globalThis, "navigator", savedNavigator);
});

/// "resolved", "rejected" or "pending" after `ms`: a copy that never settles leaves the button
/// with no answer.
const settle = (copy: Promise<void>, ms = 200): Promise<string> =>
  Promise.race([
    copy.then(
      () => "resolved",
      () => "rejected",
    ),
    new Promise<string>((resolve) => setTimeout(() => resolve("pending"), ms)),
  ]);

describe("copying an image", () => {
  beforeEach(() => {
    written = undefined;
  });

  test("a drawable image is written as PNG", async () => {
    step = "ok";
    expect(await settle(copyImage("data:image/png;base64,AAAA"))).toBe("resolved");
    expect((await written!).type).toBe("image/png");
  });

  test("a copy that cannot be drawn or encoded fails instead of hanging or copying a blank", async () => {
    for (const failing of ["drawThrows", "encodeThrows", "noContext", "noSize"] as const) {
      step = failing;
      expect(`${failing}: ${await settle(copyImage("data:image/svg+xml;base64,AAAA"))}`).toBe(`${failing}: rejected`);
    }
  });
});

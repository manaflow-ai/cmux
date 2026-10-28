// JSDOM has no bitmap decoder or canvas. Composer interaction tests supply those browser
// capabilities while running the real image preparation and attachment intake. Pixel correctness
// belongs to the browser tests; these tests observe chip, send and chat ownership behavior.
export const COMPOSER_PREVIEW = new Uint8Array([112, 114, 101, 118, 105, 101, 119]);

export function installComposerImageEngine(): () => void {
  const scope = globalThis as Record<string, unknown>;
  const keys = ["createImageBitmap", "OffscreenCanvas"] as const;
  const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
  scope.createImageBitmap = async (file: Blob) => {
    // Read through the supplied File: slowScreenshot holds this promise until release(), so
    // a send or chat switch really happens before decoding finishes.
    await file.arrayBuffer();
    return { width: 640, height: 480, close() {} };
  };
  scope.OffscreenCanvas = class {
    constructor(
      public width: number,
      public height: number,
    ) {}
    getContext() {
      return { drawImage() {}, fillRect() {}, fillStyle: "" };
    }
    async convertToBlob({ type }: { type: string }) {
      return new Blob([COMPOSER_PREVIEW], { type });
    }
  };
  return () => {
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  };
}

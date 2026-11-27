// The composer's image worker (src/agent-session/acpmux/composer/imageWorker.ts) with every
// createImageBitmap call in it reported to the page that started it, as `{ bigtestDecode }`, so a
// browser test can tell whether a picture was decoded (agent-pane-attach-huge-files.test.ts serves
// this in the worker's place). The worker's module runs first and only installs its handler; the
// spy replaces the global before the first job arrives, and the image work calls the global by name.
import "../../src/agent-session/acpmux/composer/imageWorker";

const scope = self as unknown as {
  createImageBitmap: (source: unknown, ...rest: unknown[]) => Promise<ImageBitmap>;
  postMessage(message: unknown): void;
};
const decode = scope.createImageBitmap.bind(self);
scope.createImageBitmap = (source, ...rest) => {
  const blob = source instanceof Blob ? source : undefined;
  scope.postMessage({ bigtestDecode: { where: "worker", size: blob?.size ?? -1, type: blob?.type ?? "" } });
  return decode(source, ...rest);
};

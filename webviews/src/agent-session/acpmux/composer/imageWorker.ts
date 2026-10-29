// The image worker: an attached image's preview and thumbnail (imageWork.ts), off the page's main
// thread. Built as image-worker.js beside the bundled page (scripts/cmux-next/build-agent-pane-web.sh);
// imagePool.ts starts it. Each message is one job, answered with its id.
import { prepareImage, thumbnailOf } from "./imageWork";
import type { ImageJob, ImageJobResult } from "./imagePool";

const scope = self as unknown as {
  onmessage: ((event: MessageEvent<ImageJob>) => void) | null;
  postMessage(message: ImageJobResult): void;
};

scope.onmessage = ({ data: job }) => {
  // An engine that draws on the page but not in a worker: the page does the work instead.
  if (typeof createImageBitmap !== "function" || typeof OffscreenCanvas !== "function") {
    scope.postMessage({ id: job.id, value: undefined, unsupported: true });
    return;
  }
  const work = job.kind === "prepare" ? prepareImage(job.file) : thumbnailOf(job.image);
  void work.then(
    (value) => scope.postMessage({ id: job.id, value }),
    () => scope.postMessage({ id: job.id, value: undefined }),
  );
};

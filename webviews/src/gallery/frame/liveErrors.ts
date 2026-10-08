// A stage frame on the live dev server (dev-server/galleryLive.ts). The server keeps compile errors
// outside the shell out of Vite's full-page overlay (which every open page would show) and pushes
// them as status instead; a stage shows the ones that concern it in Vite's overlay, inside the
// stage's own document. That is every `stage` error (component and page code) and its own entry
// file's. A stage opened on its own (not in the shell) also reloads when its entry file changes;
// the shell remounts its stages itself when the entry loads again.
import { liveStatus, type LiveError } from "../liveStatus";

export function watchStageErrors(entryPath: string | undefined): void {
  const hot = import.meta.hot;
  if (!hot) return;
  if (window.top === window)
    hot.on("cmux-gallery:entry", (data: { files: string[] }) => {
      if (!entryPath || data.files.includes(entryPath)) location.reload();
    });
  let shown: { error: LiveError; element: HTMLElement } | undefined;
  const relevant = (error: LiveError) => error.kind === "stage" || !entryPath || error.entries.includes(entryPath);
  const update = async () => {
    const error = liveStatus.get().errors.find(relevant);
    if (shown && shown.error.file === error?.file && shown.error.message === error.message) return;
    shown?.element.remove();
    shown = undefined;
    if (!error) return;
    const element = await overlay(error);
    shown = { error, element };
    document.body.append(element);
  };
  liveStatus.subscribe(() => void update());
  void update();
}

async function overlay(error: LiveError): Promise<HTMLElement> {
  try {
    const client = (await import(/* @vite-ignore */ `${import.meta.env.BASE_URL}@vite/client`)) as {
      ErrorOverlay: new (error: unknown, links?: boolean) => HTMLElement;
    };
    return new client.ErrorOverlay({ ...error, stack: error.stack ?? "" }, true);
  } catch {
    const element = document.createElement("pre");
    element.textContent = `${error.file}\n\n${error.message}\n\n${error.frame ?? ""}`;
    element.style.cssText =
      "position:fixed;inset:0;margin:0;padding:16px;overflow:auto;background:#181818ee;color:#ff8080;font:12px ui-monospace,monospace;white-space:pre-wrap;z-index:99999";
    return element;
  }
}

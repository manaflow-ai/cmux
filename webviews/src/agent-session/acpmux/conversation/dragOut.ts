// Drag media out of an agent chat (the user, 2026-10-21: "i need to be able to drag it out to
// other apps too"). A drag that starts on an image or a file chip (`data-path`: a path chip, a
// video or audio clip) is cancelled in the page and handed to the host, which starts its own
// drag of the real file while the person still holds the press (AgentPaneMediaDrag.swift): the
// image as a `data:` URL and its name (`image.drag`), which the host saves as a named copy; a file
// by its path (`file.drag`), which the host drags only from inside the chat's folders. A drag on
// anything else (text, a link) stays the page's.
import { postNative } from "../native";
import { dataUrl } from "./ImageViewer";

type Post = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// The image or path a drag from `target` carries, or undefined for the page's own drag.
function dragged(target: Element | null): { image: HTMLImageElement } | { path: string } | undefined {
  const image = target?.closest?.("img");
  const src = image?.getAttribute("src") ?? "";
  // A favicon or icon in a chip is part of the chip, not a picture of its own.
  if (image && (src.startsWith("data:") || src.startsWith("blob:")) && !image.closest(".cv-chip")) return { image };
  const path = target?.closest?.("[data-path]")?.getAttribute("data-path");
  return path ? { path } : undefined;
}

/// Hands drags of images and files in `doc` to the host. Returns the remover.
export function installDragOut(doc: Document, post: Post = postNative): () => void {
  const start = (event: Event) => {
    const what = dragged(event.target as Element | null);
    if (!what) return;
    event.preventDefault();
    const send =
      "path" in what
        ? post("file.drag", { path: what.path })
        : dataUrl(what.image.currentSrc || what.image.getAttribute("src") || "").then((src) =>
            post("image.drag", { src, name: what.image.getAttribute("alt") ?? "" }),
          );
    // The host refuses a drag the person no longer holds; nothing to show for it.
    void send.catch(() => {});
  };
  doc.addEventListener("dragstart", start, true);
  return () => doc.removeEventListener("dragstart", start, true);
}

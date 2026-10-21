// What `debug.agent_pane action=chat_state` reads of the queue (ComposerQueue.tsx): each queued row as
// the page draws it, so a capture slot that cannot see the window still checks a row's text and its
// thumbnails (QueuedImages.tsx keeps each one's id and state on its slot). Read-only.

export type QueuedThumbnail = "reading" | "missing" | "loading" | "loaded" | "failed";

export type QueuedRowState = {
  promptId: string;
  /// The row's text, or the edit field's while it is edited.
  text: string;
  editing: boolean;
  images: { id: string; name: string; thumbnail: QueuedThumbnail | "" }[];
};

const TEXT_NODE = 3;

export function queuedRowsState(root: ParentNode = document): QueuedRowState[] {
  return [...root.querySelectorAll<HTMLElement>(".acpmux-queued[data-prompt-id]")].map((row) => {
    const field = row.querySelector<HTMLTextAreaElement>(".acpmux-queued-edit");
    // The prompt's own words, without the Steering label drawn in front of them.
    const clamp = row.querySelector(".acpmux-queued-clamp");
    const words = [...(clamp?.childNodes ?? [])].filter((node) => node.nodeType === TEXT_NODE);
    return {
      promptId: row.dataset.promptId ?? "",
      text: field ? field.value : words.map((node) => node.textContent ?? "").join(""),
      editing: field !== null,
      images: [...row.querySelectorAll<HTMLElement>(".acpmux-queued-image-slot")].map((slot) => ({
        id: slot.dataset.imageId ?? "",
        name: slot.querySelector(".acpmux-queued-image")?.getAttribute("title") ?? "",
        thumbnail: (slot.dataset.thumbnail ?? "") as QueuedThumbnail | "",
      })),
    };
  });
}

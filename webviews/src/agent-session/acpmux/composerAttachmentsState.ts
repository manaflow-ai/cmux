// What `debug.agent_pane action=chat_state` reads of the composer's attachment tiles
// (composer/attachmentIntake.tsx, and the ones placed in the prompt, composer/inlineAttachments.tsx),
// so a capture that only sees frames can tell a tile still uploading from one that failed and why
// (Leo, 2026-10-31: "idk what's going on with video attachments"). Read-only.

export type ComposerAttachmentState = {
  /// The tile's accessible name: the file's name (an image's says it is one).
  name: string;
  /// `loading`: still read or uploaded (a send waits for it); `failed`: could not be attached;
  /// `staged`: goes with the next send.
  state: "loading" | "failed" | "staged";
  /// A failed tile's reason (its tooltip).
  reason?: string;
  /// Whether a failed tile offers Retry.
  retry?: boolean;
  /// How much of a loading tile's upload reached the host, 0 to 100, once one streams.
  percent?: number;
};

// A staged chip placed in the prompt is its strip tile inside an inline wrapper: the tile is read.
const TILES = '.acpmux-attachment, .acpmux-md-inline-chip:not([data-chip="strip"])';

export function composerAttachmentsState(root: ParentNode = document): ComposerAttachmentState[] {
  return [...root.querySelectorAll<HTMLElement>(TILES)].map((tile) => {
    const failed = tile.classList.contains("acpmux-attachment-failed") || tile.dataset.state === "failed";
    const loading = !failed && tile.getAttribute("aria-busy") === "true";
    const state = failed ? "failed" : loading ? "loading" : "staged";
    const progress = loading ? tile.querySelector<HTMLProgressElement>("progress") : null;
    return {
      name: tile.getAttribute("aria-label") ?? tile.getAttribute("title") ?? "",
      state,
      ...(failed
        ? { reason: tile.getAttribute("title") ?? "", retry: tile.querySelector(".acpmux-attachment-retry") !== null }
        : {}),
      ...(progress ? { percent: Number(progress.value) } : {}),
    };
  });
}

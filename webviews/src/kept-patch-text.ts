// The patch text the diff stream keeps on each parsed file (diff-stream.ts), so Load full files
// (diff-viewer/fullFiles.ts) can parse that file again with its two sides. Its own module, so the
// stream and the viewer share it without importing each other.

/** The file's own patch text, on its parsed diff. */
export const PATCH_TEXT_KEY = "cmuxPatchText";
/** The most a stream keeps of one file's patch (the size of one side the host sends). */
export const MAX_KEPT_PATCH_BYTES = 2 * 1024 * 1024;
/** The most a stream keeps of all its files' patches. */
export const MAX_KEPT_PATCH_TOTAL_BYTES = 64 * 1024 * 1024;

/// The card's lines (EditDiffHunks.tsx, on @pierre/diffs) come in their own chunk, so the page's
/// first script parses without Pierre (bd cx-z9kz0). The header shows at once; the page starts the
/// chunk once it has painted (App.tsx), so the lines rarely wait.
export const loadEditDiffHunks = () => import("./EditDiffHunks");

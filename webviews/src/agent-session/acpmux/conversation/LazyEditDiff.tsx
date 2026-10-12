// An opened edit's card (EditDiff.tsx, on @pierre/diffs) comes in its own chunk, so the page's
// first script parses without Pierre (bd cx-z9kz0). Rows open closed; the page starts the chunk
// once it has painted (App.tsx), so a card opened later waits on nothing.
import { lazy, Suspense } from "react";
import type { TurnFile } from "../diff";

export const loadEditDiff = () => import("./EditDiff");
const EditDiffCard = lazy(() => loadEditDiff().then((module) => ({ default: module.EditDiff })));

export function EditDiff({ file }: { file: TurnFile }) {
  return (
    <Suspense fallback={null}>
      <EditDiffCard file={file} />
    </Suspense>
  );
}

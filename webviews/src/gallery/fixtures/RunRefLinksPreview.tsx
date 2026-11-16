// l10n-allow-file: public gallery sample prose, not shipped UI.
import { Markdown } from "../../agent-session/acpmux/conversation/Markdown";

export type RunRefLook = "before" | "chip" | "plain-link";

// The coordinator's reply Leo pointed at (2026-11-10), with the other ways a reply names a run.
const REPLY = [
  "cmux#39931 merged; it ships in build 4270949510401, the nightly on your Mac.",
  "",
  "- Retried: nightly-next build #4270949510402 (attempt 2).",
  "- Shard 3 failed in run 42709495104 at 1a2b3c4d.",
  "",
  "Still text: `build 4270949510401` in code, build 2026, run 3 tests and 555-123-4567.",
].join("\n");

/// The real reply renderer; `look` only restyles the run it draws (runRefLinks.gallery.css).
export function RunRefLinksPreview({ look }: { look: RunRefLook }) {
  return (
    <div className={`run-ref-preview is-${look}`}>
      <Markdown githubRepository="manaflow-ai/cmux">{REPLY}</Markdown>
    </div>
  );
}

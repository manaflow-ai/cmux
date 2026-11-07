// l10n-allow-file: public gallery sample prose, not shipped UI.
import { Markdown } from "../../agent-session/acpmux/conversation/Markdown";

export type GithubRefLook = "before" | "chip" | "plain-link" | "link-card";

// The reply Leo pointed at (2026-11-07), with the other forms a reply names a pull request by.
const REPLY = [
  "Shipped this morning:",
  "",
  "- Relay deploy (subrouter-internal#54): live on the canary ring.",
  "- Quota guard: cmux#37758 and hq#4879; notes in lw#1234.",
  "- Upstream fix: acme/widgets#9.",
  "",
  "Still text: `cmux#1` in code, C#, F#7, color #123456 and issue #1 of 3.",
].join("\n");

/// The real reply renderer; `look` only restyles the reference it draws (githubRefLinks.gallery.css).
export function GithubRefLinksPreview({ look }: { look: GithubRefLook }) {
  return (
    <div className={`github-ref-preview is-${look}`}>
      <Markdown>{REPLY}</Markdown>
    </div>
  );
}

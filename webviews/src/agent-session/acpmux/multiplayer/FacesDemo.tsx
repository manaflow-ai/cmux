// l10n-allow-file: gallery demo (made-up prompts), not shipped UI.
// The gallery's side-by-side of the shared chat's looks (Faces.gallery.tsx): one header,
// one prompt with its author, one receipt and one typing line, in the chosen looks.
import { AnsweredBy, AuthorChip, PresenceStack, TypingLine } from "./Faces";
import type { AuthorLook, PresenceLook, TypingLook } from "./Faces";
import type { Participant } from "./participants";

export type FacesDemoProps = {
  author: AuthorLook;
  presence: PresenceLook;
  typing: TypingLook;
  viewing: Participant[];
  typers: Participant[];
  sender: Participant;
  answerer: Participant;
  /// The chat's title in the demo header (a Chief chat names its Chief).
  title?: string;
};

export function FacesDemo(props: FacesDemoProps) {
  return (
    <div className="acpmux-root" style={{ padding: 16, display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <strong>{props.title ?? "Add retries to the uploader"}</strong>
        <PresenceStack viewing={props.viewing} look={props.presence} />
      </div>
      <div className="cv-user">
        <AuthorChip author={props.sender} look={props.author} />
        <div className="ui-glass cv-user__bubble">Cover the retry with a test that fakes two timeouts</div>
      </div>
      <div className="acpmux-permission-record" data-decision="allowed">
        Allowed: bun test uploader
        <AnsweredBy person={props.answerer} />
      </div>
      <TypingLine typing={props.typers} look={props.typing} />
    </div>
  );
}

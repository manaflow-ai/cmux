// The people in a shared chat, drawn (participants.ts reads them): a face, the author over a
// prompt, the faces of who else is here in the header, who is typing above the composer, and who
// answered an ask. Render only: no timer, no observer; the typing dots are a CSS wave that reduced
// motion stills.
import "./multiplayer.css";
import { useT } from "../i18n";
import { machineColor } from "../machineColor";
import { useAvatarPicture } from "../../../pages/home-channels/avatars";
import { initials, type Participant } from "./participants";

/// Faces the header shows before "+N".
export const PRESENCE_STACK = 3;

/// A person's picture, or their initials on their own hue (the hash the pane gives machines). The
/// picture is the record's, else the one Home's avatar service has for that id (avatars.ts; a page
/// without the service, such as the agent pane today, reads none).
export function Face({ person, size = 16 }: { person: Participant; size?: number }) {
  const served = useAvatarPicture(person.avatar ? undefined : person.id);
  const picture = person.avatar ?? served ?? undefined;
  return (
    <span
      className="cv-face"
      style={{ width: size, height: size, fontSize: Math.round(size * 0.45), background: machineColor(person.name) }}
      aria-hidden="true"
    >
      {/* A small face has room for one letter, as Home's avatars. */}
      {picture ? <img src={picture} alt="" draggable={false} /> : initials(person.name, size >= 24 ? 2 : 1)}
    </span>
  );
}

export type AuthorLook = "face-name" | "name" | "face";

/// Who sent a prompt, over its bubble: their face and name (the pick), the name alone, or the
/// face alone with the name for screen readers.
/// `inline` draws it in a line of text (a queued prompt's row), ahead of the words.
export function AuthorChip({
  author,
  look = "face-name",
  inline = false,
}: {
  author: Participant;
  look?: AuthorLook;
  inline?: boolean;
}) {
  const Root = inline ? "span" : "div";
  return (
    <Root className={inline ? "cv-author cv-author--inline" : "cv-author"} data-look={look}>
      {look !== "name" && <Face person={author} />}
      <span className={look === "face" ? "cv-author__name cv-author__name--hidden" : "cv-author__name"}>
        {author.name}
      </span>
    </Root>
  );
}

export type PresenceLook = "stack" | "names";

/// Who else has the chat open, in the header: overlapping faces with "+N" (the pick), or faces
/// with first names. Nothing when the reader is alone.
export function PresenceStack({ viewing, look = "stack" }: { viewing: Participant[]; look?: PresenceLook }) {
  const t = useT();
  if (viewing.length === 0) return null;
  const shown = viewing.slice(0, PRESENCE_STACK);
  const names = viewing.map((person) => person.name).join(", ");
  return (
    <div className="cv-presence" data-look={look}>
      <span className="cv-presence__label">{t("multiplayer.viewing", { names })}</span>
      {shown.map((person) => (
        <span key={person.id} className="cv-presence__person" aria-hidden="true" title={person.name}>
          <Face person={person} size={20} />
          {look === "names" && <span className="cv-presence__name">{person.name.split(/\s+/)[0]}</span>}
        </span>
      ))}
      {viewing.length > shown.length && (
        <span className="cv-presence__more" aria-hidden="true">
          {t("multiplayer.more", { count: viewing.length - shown.length })}
        </span>
      )}
    </div>
  );
}

export type TypingLook = "dots" | "faces" | "text";

/// "Ana is typing…" over the composer while someone else types: their face, the words and a
/// three-dot wave (the pick); faces with the wave; or the words alone.
export function TypingLine({ typing, look = "dots" }: { typing: Participant[]; look?: TypingLook }) {
  const t = useT();
  if (typing.length === 0) return null;
  const words =
    typing.length === 1
      ? t("multiplayer.typing.one", { name: typing[0]!.name })
      : typing.length === 2
        ? t("multiplayer.typing.two", { first: typing[0]!.name, second: typing[1]!.name })
        : t("multiplayer.typing.many", { count: typing.length });
  return (
    <output className="cv-typing" data-look={look} aria-live="polite">
      {look !== "text" && (
        <span className="cv-typing__faces">
          {typing.slice(0, PRESENCE_STACK).map((person) => (
            <Face key={person.id} person={person} />
          ))}
        </span>
      )}
      <span className={look === "faces" ? "cv-typing__words cv-typing__words--hidden" : "cv-typing__words"}>
        {words}
      </span>
      {look !== "text" && (
        <span className="cv-typing__dots" aria-hidden="true">
          <i />
          <i />
          <i />
        </span>
      )}
    </output>
  );
}

/// "Answered by Ana" after an ask's receipt.
export function AnsweredBy({ person }: { person: Participant }) {
  const t = useT();
  return (
    <span className="cv-answered-by">
      <Face person={person} size={14} />
      {t("multiplayer.answeredBy", { name: person.name })}
    </span>
  );
}

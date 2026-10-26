// The people in a shared chat, drawn (participants.ts reads them): a face, the author over a
// prompt, the faces of who else is here in the header, who is typing above the composer, and who
// answered an ask. Render only: no timer, no observer; the typing dots are a CSS wave that reduced
// motion stills.
import "./multiplayer.css";
import { useT } from "../i18n";
import { machineColor } from "../machineColor";
import { initials, type Participant } from "./participants";

/// Faces the header shows before "+N".
export const PRESENCE_STACK = 3;

/// A person's picture, or their initials on their own hue (the hash the pane gives machines).
export function Face({ person, size = 16 }: { person: Participant; size?: number }) {
  return (
    <span
      className="cv-face"
      style={{ width: size, height: size, fontSize: Math.round(size * 0.45), background: machineColor(person.name) }}
      aria-hidden="true"
    >
      {person.avatar ? <img src={person.avatar} alt="" draggable={false} /> : initials(person.name)}
    </span>
  );
}

export type AuthorLook = "face-name" | "name" | "face";

/// Who sent a prompt, over its bubble: their face and name (the pick), the name alone, or the
/// face alone with the name for screen readers.
export function AuthorChip({ author, look = "face-name" }: { author: Participant; look?: AuthorLook }) {
  return (
    <div className="cv-author" data-look={look}>
      {look !== "name" && <Face person={author} />}
      <span className={look === "face" ? "cv-author__name cv-author__name--hidden" : "cv-author__name"}>
        {author.name}
      </span>
    </div>
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
    <div className="cv-presence" data-look={look} role="img" aria-label={t("multiplayer.viewing", { names })}>
      {shown.map((person) => (
        <span key={person.id} className="cv-presence__person" title={person.name}>
          <Face person={person} size={20} />
          {look === "names" && <span className="cv-presence__name">{person.name.split(/\s+/)[0]}</span>}
        </span>
      ))}
      {viewing.length > shown.length && (
        <span className="cv-presence__more">{t("multiplayer.more", { count: viewing.length - shown.length })}</span>
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
    <div className="cv-typing" data-look={look} role="status" aria-live="polite">
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
    </div>
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

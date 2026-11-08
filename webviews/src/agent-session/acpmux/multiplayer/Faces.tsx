// The people in a shared chat, drawn (participants.ts reads them): a face, the author over a
// prompt, the faces of who else is here in the header, who is typing above the composer, and who
// answered an ask. Render only: no timer, no observer; the typing dots are a CSS wave that reduced
// motion stills.
import "./multiplayer.css";
import { useEffect, useState } from "react";
import { callChipHost } from "../chips/host";
import { useT } from "../i18n";
import { machineColor } from "../machineColor";
import { useAvatarPicture } from "../../../pages/home-channels/avatars";
import { initials, isGuest, type Participant } from "./participants";
import { PRESENCE_STACK } from "./facesModel";

/// An https picture the page could not load itself, as the host loaded it (`data:`), or null when the
/// host would not: asked once per link for the page's life.
const inlined = new Map<string, string | null>();
const inlining = new Map<string, Promise<string | null>>();

/// Asks the host for an https picture as an inline image (the chip host's `image.load`, `auto`: the
/// host applies the person's remote-image setting and spends no click). A page without a host (the
/// guest page) answers nothing.
function inline(src: string): Promise<string | null> {
  const known = inlined.get(src);
  if (known !== undefined) return Promise.resolve(known);
  let asked = inlining.get(src);
  if (!asked) {
    asked = callChipHost("image.load", { src, auto: true }).then((reply) => {
      const data = (reply as { src?: unknown } | undefined)?.src;
      const shown = typeof data === "string" && data.startsWith("data:image/") ? data : null;
      inlined.set(src, shown);
      inlining.delete(src);
      return shown;
    });
    inlining.set(src, asked);
  }
  return asked;
}

/// A person's picture, or their initials on their own hue (the hash the pane gives machines). The
/// picture is the record's, else the one Home's avatar service has for that id (avatars.ts; a page
/// without the service, such as the agent pane today, reads none).
/// An https picture (a signed-in guest's `fromAvatar`) loads as itself where the page may load it
/// (the guest page); where the page's policy refuses links (the app's `img-src data:`), the host
/// loads it inline, and a picture neither can load draws the initials.
/// `size` is pixels, or a CSS length that scales with the interface (the author line's
/// `var(--cv-author-face)`); a length draws one initial.
export function Face({ person, size = 16 }: { person: Participant; size?: number | string }) {
  const served = useAvatarPicture(person.avatar ? undefined : person.id);
  const wanted = person.avatar ?? served ?? undefined;
  const [broken, setBroken] = useState<string>();
  const [hosted, setHosted] = useState<{ src: string; data: string | null }>();
  const remote = wanted?.startsWith("https://") === true;
  const known = remote && wanted ? inlined.get(wanted) : undefined;
  useEffect(() => {
    if (!remote || !wanted || broken !== wanted || known !== undefined) return;
    let live = true;
    void inline(wanted).then((data) => live && setHosted({ src: wanted, data }));
    return () => {
      live = false;
    };
  }, [remote, wanted, broken, known]);
  const fromHost = known ?? (hosted && hosted.src === wanted ? hosted.data : undefined);
  // An https picture the page could not load (or the host already inlined) shows the host's copy;
  // any other picture that does not load shows the initials.
  const picture = !wanted
    ? undefined
    : remote && (broken === wanted || known)
      ? (fromHost ?? undefined)
      : broken === wanted
        ? undefined
        : wanted;
  return (
    <span
      className="cv-face"
      style={{
        width: size,
        height: size,
        fontSize: typeof size === "number" ? Math.round(size * 0.45) : `calc(${size} * 0.45)`,
        background: machineColor(person.name),
      }}
      aria-hidden="true"
    >
      {/* A small face has room for one letter, as Home's avatars. */}
      {picture ? (
        <img
          src={picture}
          alt=""
          draggable={false}
          // A profile picture link tells its host nothing about the chat it is drawn in.
          referrerPolicy="no-referrer"
          onError={() => setBroken(picture)}
        />
      ) : (
        initials(person.name, typeof size === "number" && size >= 24 ? 2 : 1)
      )}
    </span>
  );
}

export type AuthorLook = "face-name" | "name" | "face";

/// Who sent a prompt, over its bubble: their face and name (the pick), the name alone, or the
/// face alone with the name for screen readers. A link guest's name reads "<name> (guest)", as
/// their held card does (IncomingMessageCard.tsx `PersonName`), so the owner still sees who wrote it
/// once it is approved. The face is a person's picture beside their name, at `--cv-author-face`
/// (multiplayer.css: the header's person faces), so a guest's message reads as a person's, not a
/// 14px mark (Leo, 2026-11-07: "as if the user sent it, but, like, with their profile avatar picture
/// instead").
/// `inline` draws it in a line of text (a queued prompt's row), ahead of the words, as a 16 mark.
export function AuthorChip({
  author,
  look = "face-name",
  inline = false,
}: {
  author: Participant;
  look?: AuthorLook;
  inline?: boolean;
}) {
  const t = useT();
  const Root = inline ? "span" : "div";
  return (
    <Root className={inline ? "cv-author cv-author--inline" : "cv-author"} data-look={look}>
      {look !== "name" && <Face person={author} size={inline ? 16 : "var(--cv-author-face)"} />}
      <span className={look === "face" ? "cv-author__name cv-author__name--hidden" : "cv-author__name"}>
        {isGuest(author) ? t("multiplayer.guestName", { name: author.name }) : author.name}
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

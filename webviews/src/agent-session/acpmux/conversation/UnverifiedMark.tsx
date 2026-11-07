// The one sign that acpmux could not verify who sent a message (senderIdentity.ts): a small muted
// mark by the sender's name, its tooltip and accessible name "Sender not verified". Never words in
// the name (Leo, 2026-11-07: "Why does it say blah blah unauthenticated? ... Why does it say it's
// self-declared if we can just detect the thing?"). It never shifts the row: it is the size of a
// status mark and sits in the sentence's flow, or on the icon's corner in the `corner` look.
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";

export function UnverifiedMark({ className }: { className?: string }) {
  const t = useT();
  const label = t("message.senderUnverified");
  return (
    // A glyph with a name, no image file: the mark's words are its label and tooltip.
    <span
      className={`cv-unverified${className ? ` ${className}` : ""}`}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an icon glyph, not an image file
      role="img"
      aria-label={label}
      title={label}
      data-find-skip=""
    >
      <Icon name="agent.question" size={12} />
    </span>
  );
}

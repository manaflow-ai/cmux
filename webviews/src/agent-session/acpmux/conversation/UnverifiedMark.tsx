// The one sign that acpmux could not verify who sent a message (senderIdentity.ts): a small muted
// mark by the sender's name. Never words in the name (Leo, 2026-11-07: "Why does it say blah blah
// unauthenticated? ... Why does it say it's self-declared if we can just detect the thing?"). It
// never shifts the row: it is the size of a status mark and sits in the sentence's flow, or on the
// icon's corner in the `corner` look. Its tooltip and accessible name say why, from what acpmux
// itself found behind the send (unverifiedSender.ts): "Claimed to be glaeda-gh, not proven" and
// "Sent by outbox_relay.py via acpmux CLI on cosmic-gray" (Leo, 2026-11-11: "generally the
// "unverified sender" things should be more verified"); "Sender not verified" with nothing more.
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { unverifiedWhy, type UnverifiedWhy } from "./unverifiedSender";

export function UnverifiedMark({ className, why }: { className?: string; why?: UnverifiedWhy }) {
  const t = useT();
  const label = why ? unverifiedWhy(t, why) : t("message.senderUnverified");
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

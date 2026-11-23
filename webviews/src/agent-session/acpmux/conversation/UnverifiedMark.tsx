// The one sign that acpmux could not verify who sent a message (senderIdentity.ts): a small muted
// mark by the sender's name, its tooltip and accessible name "Sender not verified". Never words in
// the name (Leo, 2026-11-07: "Why does it say blah blah unauthenticated? ... Why does it say it's
// self-declared if we can just detect the thing?"). It never shifts the row: it is the size of a
// status mark and sits in the sentence's flow, or on the icon's corner in the `corner` look.
// A sender acpmux saw as a program (incomingMessage.ts `senderProgram`: a fleet tool's `acpmux
// send`) draws a terminal prompt instead, and says what acpmux checked: "Program checked by
// acpmux: next-autoland on build-box", that no agent was proven, and the program's path (Leo,
// 2026-11-11: "generally the "unverified sender" things should be more verified").
// A sender that only named itself (`--from`, a notice's sender) says that name is its claim:
// "Claimed to be ci-watch, not proven". One of our own tools proves its name with the host's
// sender token (acpmux sender_token.rs) and draws no mark at all.
import { useT, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import type { SenderProgram } from "./incomingMessage";

/// The program mark's accessible name, and its tooltip's lines (the path last, when acpmux read one).
export function programMarkText(t: Translate, program: SenderProgram): { label: string; title: string } {
  const who = program.host
    ? t("message.senderProgramOnHost", { name: program.name, host: program.host })
    : program.name;
  const label = t("message.senderProgram", { program: who });
  const title = [label, t("message.senderProgramNotAgent"), program.path].filter(Boolean).join("\n");
  return { label, title };
}

export function UnverifiedMark({
  className,
  program,
  claimed,
}: {
  className?: string;
  program?: SenderProgram;
  /// The name the sender gave itself, which acpmux did not prove.
  claimed?: string;
}) {
  const t = useT();
  const checked = program && programMarkText(t, program);
  const name = claimed?.trim();
  const label = checked
    ? checked.label
    : name
      ? t("message.claimedNotProven", { name })
      : t("message.senderUnverified");
  return (
    // A glyph with a name, no image file: the mark's words are its label and tooltip.
    <span
      className={`cv-unverified${checked ? " is-program" : ""}${className ? ` ${className}` : ""}`}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an icon glyph, not an image file
      role="img"
      aria-label={label}
      title={checked ? checked.title : label}
      data-find-skip=""
    >
      <Icon name={checked ? "terminal.prompt" : "agent.question"} size={12} />
    </span>
  );
}

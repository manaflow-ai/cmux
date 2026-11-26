// A received message from a sender acpmux saw as a program (incomingMessage.ts `senderProgram`: a
// fleet tool's `acpmux send`) draws a small terminal prompt by the sender's name, and says what
// acpmux checked: "Program checked by acpmux: next-autoland on build-box", that no agent was
// proven, and the program's path (Leo, 2026-11-11: "generally the "unverified sender" things should
// be more verified"). It never shifts the row: it is the size of a status mark and sits in the
// sentence's flow, or on the icon's corner in the `corner` look.
// A sender that only named itself draws no mark: the old question bubble is gone (Leo, 2026-11-25:
// "get rid of this tiny icon it's been bugging me for a while"). Never words in the name either
// (Leo, 2026-11-07: "Why does it say blah blah unauthenticated?").
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

export function UnverifiedMark({ className, program }: { className?: string; program?: SenderProgram }) {
  const t = useT();
  if (!program) return null;
  const checked = programMarkText(t, program);
  return (
    // A glyph with a name, no image file: the mark's words are its label and tooltip.
    <span
      className={`cv-unverified is-program${className ? ` ${className}` : ""}`}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an icon glyph, not an image file
      role="img"
      aria-label={checked.label}
      title={checked.title}
      data-find-skip=""
    >
      <Icon name="terminal.prompt" size={12} />
    </span>
  );
}

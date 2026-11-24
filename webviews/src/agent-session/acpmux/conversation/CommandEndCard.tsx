// A background command's Shell card, the same on every surface that draws one: the chat row of a
// finished background command (BackgroundTurnLine.tsx, BackgroundTaskNote.tsx, CommandRow.tsx) and
// the composer hat's and Background tasks panel's card (backgroundTasks/BackgroundTaskCard.tsx).
// It always shows three things (Leo, 2026-11-24, on a card that showed only "Finished": "but i
// couldnt... do anything?"): the command line, how it stands ("Exit code 0" muted, "Exit code 1" in
// the error tone, "Running", "Stopped"), and the end of what it printed, else why there is none ("No
// output", "No output yet", "Output no longer available"). What it shows is acpmux's
// (hub/command_end.rs, commandEnd.ts); this only words it.
import type { ReactNode } from "react";
import { useT, type Translate } from "../i18n";
import type { AcpmuxCommandEnd } from "../model";
import { ShellBlock } from "./ShellBlock";

/// The status line a command's end draws: its exit code once it has one, else its state's word.
export function commandEndStatus(
  t: Translate,
  end: Partial<AcpmuxCommandEnd>,
): { text: string; failed: boolean } | undefined {
  if (end.state === "running") return { text: t("bgTask.state.running"), failed: false };
  if (end.exitCode !== undefined) return { text: t("shell.exit", { code: end.exitCode }), failed: end.exitCode !== 0 };
  if (end.state === "failed" || end.state === "lost") return { text: t("bgTask.state.failed"), failed: true };
  if (end.state === "stopped") return { text: t("bgTask.state.stopped"), failed: false };
  if (end.state === "completed") return { text: t("bgTask.state.completed"), failed: false };
  return undefined;
}

/// What the card says where the output would be, when there is none to show.
export function commandEndNote(t: Translate, end: Partial<AcpmuxCommandEnd>): string | undefined {
  if (end.output?.trim()) return undefined;
  if (end.outputState === "gone") return t("shell.outputGone");
  if (end.outputState !== "empty") return undefined;
  return end.state === "running" ? t("backgroundTasks.noOutputYet") : t("shell.noOutput");
}

export function CommandEndCard({
  id,
  end,
  took,
  footer,
  whole,
}: {
  id?: string;
  end: Partial<AcpmuxCommandEnd>;
  took?: string;
  footer?: ReactNode;
  whole?: boolean;
}) {
  const t = useT();
  const output = end.output?.replace(/\n$/, "") || undefined;
  return (
    <ShellBlock
      id={id}
      command={end.command || undefined}
      output={output}
      cut={end.cut}
      exitCode={end.exitCode}
      status={commandEndStatus(t, end)}
      note={commandEndNote(t, end)}
      live={end.state === "running"}
      took={took}
      footer={footer}
      whole={whole}
    />
  );
}

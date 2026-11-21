import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import type { SleepHandoffNote } from "./sleepHandoffNote";

/// Keep Chats Running When This Mac Sleeps: one quiet line in the composer notice slot, in the
/// host line's shape (design/sleep-handoff.md). This Mac's copy of a moved chat says where it went
/// and opens it there when the chat list has it (`canOpen`).
export function SleepHandoffNotice({
  note,
  canOpen,
  onOpen,
}: {
  note: SleepHandoffNote | undefined;
  canOpen: boolean;
  onOpen: (sessionId: string) => void;
}) {
  const t = useT();
  const tier = note?.kind === "moved" || note?.kind === "running" ? "status" : "hint";
  return (
    <Notice id="sleep-handoff" tier={tier} when={note}>
      {note && (
        <output className="acpmux-host-line" data-sleep-handoff={note.kind}>
          <p className="acpmux-host-line-message selectable">{noteText(t, note)}</p>
          {note.kind === "moved" && canOpen && note.routed && (
            <button type="button" className="acpmux-host-line-quiet" onClick={() => onOpen(note.routed!)}>
              {t("sleepHandoff.open")}
            </button>
          )}
        </output>
      )}
    </Notice>
  );
}

function noteText(t: ReturnType<typeof useT>, note: SleepHandoffNote): string {
  switch (note.kind) {
    case "moved":
      return t("sleepHandoff.moved", { machine: note.machine });
    case "running":
      return note.machine
        ? t("sleepHandoff.running", { machine: note.machine, from: note.from })
        : t("sleepHandoff.runningHere", { from: note.from });
    case "ran":
      return note.machine
        ? t("sleepHandoff.ran", { machine: note.machine, from: note.from })
        : t("sleepHandoff.ranHere", { from: note.from });
    case "stayed":
      return t("sleepHandoff.stayed", { why: note.why });
  }
}

import { memo } from "react";
import { useSessionRecapOn } from "../chatDisplay";
import { RecapNote } from "../conversation/RecapNote";
import { SinceDivider } from "../conversation/SinceDivider";
import { type RowProps } from "./rowProps";
import { dismissRecap } from "./rowActions";

/// A session recap row. Off in Settings (Session Recap), it draws nothing, unless the chat's own
/// option turned it on (`chatOn`).
export const RecapRow = memo(
  function RecapRow({ row }: RowProps) {
    const on = useSessionRecapOn();
    const recap = row.recap;
    return recap && (on || recap.chatOn) ? (
      <RecapNote recap={recap} onDismiss={() => dismissRecap(row.id, recap.key)} />
    ) : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// A recap in a read-only, replayed or read-only subagent transcript: no ×, which would do nothing
/// for a guest and act on the live chat from the others.
export const ReadOnlyRecapRow = memo(
  function ReadOnlyRecapRow({ row }: RowProps) {
    const on = useSessionRecapOn();
    return row.recap && (on || row.recap.chatOn) ? <RecapNote recap={row.recap} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);

/// "New since you looked" (conversation/SinceDivider.tsx), with the recap made for the same return.
export const SinceRow = memo(
  function SinceRow({ row }: RowProps) {
    const since = row.since;
    const recap = since?.recap;
    return since ? (
      <SinceDivider since={since} onDismissRecap={recap ? () => dismissRecap(row.id, recap.key) : undefined} />
    ) : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// The same in a read-only transcript: its recap draws no ×.
export const ReadOnlySinceRow = memo(
  function ReadOnlySinceRow({ row }: RowProps) {
    return row.since ? <SinceDivider since={row.since} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);

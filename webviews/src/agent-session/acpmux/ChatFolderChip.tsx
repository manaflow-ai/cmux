import { chatFolderFace, FOLDER_CHIP_LABELS, startedCloudFolderName } from "./folderlessCloud";
import { useT, type StringKey } from "./i18n";
import type { AcpmuxSnapshot } from "./model";
import { FolderIcon } from "./NewTabPage";
import "./chatFolderChip.css";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

/// What a started chat's folder chip says: the folder it works in by name (`/Users/you/src/cmux`
/// reads "cmux"; a Cloud chat names its folder on its machine), a Cloud chat still in its machine's
/// fresh folder by that folder's name, and a chat in its private folder No folder (`key`, the
/// translation key of its words). Undefined while the chat's
/// folder is not known (a reopened chat whose summary has not arrived), so the chip never guesses.
export function startedChatFolderFace(
  summary: Pick<Summary, "cwd" | "hostKind"> | undefined,
): { label: string; title: string } | { key: StringKey } | undefined {
  const cwd = summary?.cwd;
  if (!cwd) return undefined;
  const cloud = summary.hostKind === "cloud";
  const fresh = startedCloudFolderName(cwd, { cloud, started: true });
  if (fresh !== undefined) return { label: fresh, title: cwd };
  const face = chatFolderFace(cwd, cloud);
  if (face.name) return { label: face.name, title: cwd };
  return { key: FOLDER_CHIP_LABELS[face.state] };
}

/// A started chat's folder in the composer's quiet row, after the mode chip (cmux#46201): the
/// location strip over the card is a new chat's only (locationRow.ts `showsLocationRow`), so once
/// the chat has its first send this label is where the person still sees which project the chat is
/// in. A plain label: a started chat's folder does not change from here (`/cd` moves it).
export function ChatFolderChip({ summary }: { summary: Pick<Summary, "cwd" | "hostKind"> | undefined }) {
  const t = useT();
  const face = startedChatFolderFace(summary);
  if (!face) return null;
  const label = "key" in face ? t(face.key) : face.label;
  return (
    <span className="acpmux-chat-folder" title={"key" in face ? label : face.title}>
      <span className="acpmux-chat-folder-icon" aria-hidden="true">
        <FolderIcon />
      </span>
      <span className="acpmux-chat-folder-name">{label}</span>
    </span>
  );
}

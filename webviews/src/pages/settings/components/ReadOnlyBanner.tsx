import { ConnectionChip } from "../../../ui/ConnectionChip";
import { useConnectionQuiet } from "../../../ui/lasting";
import { Icon } from "../icons";
import { t } from "../strings";

/** Why the page is read only: the daemon is away, or its first read failed. A failed first read is a
 *  banner that drops in from the top of the page (ui/popupSurface.css `data-enter`); a lost link is a
 *  mark in the corner (ui/ConnectionChip.tsx) that takes no room, so the rows never move. */
export function ReadOnlyBanner({ reason = "disconnected" }: { reason?: "disconnected" | "loadFailed" }) {
  if (reason === "disconnected")
    return <ConnectionChip text={t("settingsPage.readOnly")} dataAttrs={{ "data-read-only": "disconnected" }} />;
  return (
    <output className="banner" data-read-only={reason} data-enter="top">
      <Icon name="warning" />
      {t("settingsPage.loadFailed")}
    </output>
  );
}

/** The page's read-only banner, if any. A lost link says so only once it lasts (ui/lasting.ts, the shared 10 s): a
 *  daemon restart or an update's handoff drops it for a few seconds and the values on the page stay
 *  as they were, so the person has nothing to do (Leo, 2026-11-14: "i also want all our connectivity
 *  stuff to shut the f*** up"). It dropped in at once on every restart. */
export function ReadOnlyNotice({
  connected,
  loaded,
  readable,
}: {
  connected: boolean;
  loaded: boolean;
  readable: boolean;
}) {
  const downLasting = useConnectionQuiet(!connected);
  if (!connected) return downLasting ? <ReadOnlyBanner /> : null;
  return loaded && !readable ? <ReadOnlyBanner reason="loadFailed" /> : null;
}

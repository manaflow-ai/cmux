import { type ContextMenuItem } from "../../../ui/ContextMenu";
import { type NowPlayingTrack } from "./nowPlaying";
import { type NewTabTranslate } from "./strings";

/// The transport controls, and the menu's page actions: `open` brings the app that plays forward,
/// `hide` turns the New Tab player off (`tabs.newTabNowPlaying`), `show` undoes that, and
/// `settings` opens Settings at that row.
export type NowPlayingCommand = "playPause" | "previous" | "next" | "open" | "hide" | "show" | "settings";

/// The card's right-click menu, in the order of the transport row, then the page's own items.
export function nowPlayingMenuItems(
  track: NowPlayingTrack,
  nt: NewTabTranslate,
  onCommand: (command: NowPlayingCommand) => void,
): ContextMenuItem[] {
  const { labels } = track;
  const items: ContextMenuItem[] = [
    { id: "playPause", label: track.playing ? labels.pause : labels.play, onSelect: () => onCommand("playPause") },
    { id: "next", label: labels.next, disabled: !track.canNext, onSelect: () => onCommand("next") },
    { id: "previous", label: labels.previous, disabled: !track.canPrevious, onSelect: () => onCommand("previous") },
  ];
  if (track.source)
    items.push({
      id: "open",
      label: nt("nowPlaying.openIn", { app: track.source }),
      onSelect: () => onCommand("open"),
    });
  items.push(
    { id: "hide", label: nt("nowPlaying.hide"), separatorBefore: true, onSelect: () => onCommand("hide") },
    { id: "settings", label: nt("nowPlaying.settings"), onSelect: () => onCommand("settings") },
  );
  return items;
}

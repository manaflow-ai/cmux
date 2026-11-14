// The pane's toasts (paneToasts.ts): the shared stack (ui/NoticeStack) as a deck over the
// transcript's foot, just above the bottom stack (bottomStack.css), centred on the composer's
// column, where the person is looking while text streams in (Leo, 2026-11-07: "I'm often looking at
// the bottom because the composer's at the bottom"). It lies over the transcript and takes no room:
// the composer and the rows never move when a toast comes or goes. A toast dragged elsewhere
// settles at one of six anchors (ui/anchors.ts): the bottom row stands on this same line, so a
// bottom toast still never covers the composer; the top row hangs under the chat's header.
import type { DeckAlign, DragFeel } from "../../ui/NoticeDeck";
import { NoticeStack, type NoticeQueue, type StackLayout } from "../../ui/NoticeStack";
import { useT } from "./i18n";
import "./toastLayer.css";

/// `layout` and `align` are the gallery's compared options; the pane ships the default deck.
export function ToastLayer({
  queue,
  topHost,
  layout = "stacked",
  align = "center",
  drag = "ghosts",
}: {
  queue: NoticeQueue;
  /** The box at the chat's top edge (under the header) where the top anchors' decks are drawn. */
  topHost?: HTMLElement | null;
  layout?: StackLayout;
  align?: DeckAlign;
  /** How a dragged toast feels; the pane ships `ghosts` (ToastLayer.gallery.tsx says why). */
  drag?: DragFeel;
}) {
  const t = useT();
  return (
    <div className="acpmux-toasts">
      <NoticeStack
        queue={queue}
        layout={layout}
        align={align}
        drag={drag}
        topHost={topHost}
        dismissLabel={t("toast.dismiss")}
      />
    </div>
  );
}

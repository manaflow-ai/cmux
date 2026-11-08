// Boots the omnibar star's edit bubble (`cmux-page://cmux.bookmark-edit/`), a page in a native glass
// popup under the star (CmuxNextBookmarks BookmarkEditBubble through CmuxNextPages
// BrowserChromeWebHost). The host pushes the bookmark and the daemon's folder choices on
// `cmux.bookmark-edit.state`, numbered; the page sends each edit and button on
// `cmux.bookmark-edit.command` and the height of each state on `cmux.bookmark-edit.size`. The
// Folder menu shows through the app's popup host, past the card's edge.
import "../shared/desktop";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { appPopupHost } from "../shared/pagePopupHost";
import { mountChromePage } from "../../browser-chrome/page-info/mountChromePage";
import { BookmarkEditBubble } from "../../browser-chrome/bookmark-edit/BookmarkEditBubble";
import {
  APP_BOOKMARK_EDIT_LOOK,
  bookmarkEditState,
  type BookmarkEditCommand,
} from "../../browser-chrome/bookmark-edit/model";
import { bookmarkEditStrings } from "../../browser-chrome/bookmark-edit/strings";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

export function mountBookmarkEditPage(root: HTMLElement, client: PageClient): () => void {
  return mountChromePage<unknown, BookmarkEditCommand>(root, client, {
    page: "bookmark-edit",
    strings: bookmarkEditStrings(),
    popupHost: appPopupHost(client),
    focus: ".be-card",
    // The native popup's card is the glass; the page draws only the fields.
    render: (raw, send, strings) => {
      const state = bookmarkEditState(raw);
      return state ? (
        <BookmarkEditBubble
          state={state}
          onCommand={send}
          strings={strings}
          look={APP_BOOKMARK_EDIT_LOOK}
          glass={false}
        />
      ) : null;
    },
  });
}

const root = document.getElementById("root");
const client = createPageClient();
if (root && client && document.documentElement.dataset.cmuxPage === "bookmark-edit")
  mountBookmarkEditPage(root, client);

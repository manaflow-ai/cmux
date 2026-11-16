// Reader mode, built only on cmux-extension-sdk. One command, `Reader Mode: Toggle` (Shift+R on a
// browser page): it lays the article (title, byline, text, images) over the page as clean, readable
// text, with no ads, menus or popups; the same key takes it away again. The work happens in the
// page (src/page.js, one script per toggle), so nothing big crosses into the extension.
import { browserPage, command } from "cmux-extension-sdk"
import PAGE_SCRIPT from "./page.js" with { type: "text" }

/** What the page script answers. */
export interface ReaderState {
  reader: boolean
  reason?: "no_article" | "no_browser"
  title?: string
  words?: number
  minutes?: number
}

// The export catalog.json names for local.reader_mode.toggle. A page key passes {tab}.
export const toggle = command(async (args: { tab?: string }, { cmux }): Promise<ReaderState> => {
  try {
    const value = await browserPage(cmux).eval<ReaderState>(PAGE_SCRIPT, { tab: args?.tab })
    if (value?.reason === "no_article") await cmux.toast({ title: "No article to read on this page", tone: "warning" })
    return value
  } catch (error) {
    if ((error as { code?: string })?.code !== "not_found") throw error
    await cmux.toast({ title: "Reader mode works in a browser tab", tone: "warning" })
    return { reader: false, reason: "no_browser" }
  }
})

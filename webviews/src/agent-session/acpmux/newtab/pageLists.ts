// What each snapshot of a page's own daemon connection leaves for the next New Tab page (App.tsx calls
// this for every one, chat pages included): the folders used last (recentProject.ts), the shared chat
// store (chatStore.ts) and the host's warm list (warmSnapshot.ts). Only a page that shows a New Tab
// (`showsNewTab`, the prewarmed spare among them) writes the store and posts the list; a chat page only
// holds its newest list, read for its folders when it hides or a New Tab mounts. A chat page sorted, stringified and
// wrote all of its chats twice a second for pages that never showed them (Leo, 2026-11-18: "Why
// should non visible thing even affect the renderer thread anyways?";
// test/chat-page-unseen-work.test.ts).
import type { AcpmuxSnapshot } from "../model";
import { publishSessions } from "./chatStore";
import { rememberRecentFolders } from "./recentProject";
import { publishWarmNewTab } from "./warmSnapshot";

export function keepListsForNewTab(
  next: AcpmuxSnapshot,
  showsNewTab: boolean,
  post: Parameters<typeof publishWarmNewTab>[1],
): void {
  rememberRecentFolders(next, showsNewTab);
  publishSessions(next, undefined, showsNewTab);
  publishWarmNewTab(next, post, showsNewTab);
}

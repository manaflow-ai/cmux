// The guest page has no owner host (design/chat-multiplayer.md section 5: a guest gets one chat's
// transcript and nothing else). Every way the pane's code reaches a host answers nothing here:
// native calls refuse before any page host or WebKit handler is looked for (so a guest page opened
// in cmux's own browser never reaches that app), chip calls refuse, and no bookmark transport,
// message-menu source or pane action table exists. Installed before the page draws (main.tsx).
import { setChipHost } from "../acpmux/chips/host";
import { setMessageMenuSource } from "../acpmux/conversation/messageMenu";
import { setNativeHost } from "../acpmux/native";
import { NativeError } from "../acpmux/nativeError";
import { setBookmarkTransport } from "../acpmux/threadMinimap/bookmarks";

const refuse = (): Promise<never> => Promise.reject(new NativeError({ code: "native.unsupported", origin: "native" }));

export function installGuestHost(): void {
  setNativeHost(refuse);
  setChipHost(refuse);
  setBookmarkTransport(undefined);
  setMessageMenuSource(undefined);
  delete (window as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
}

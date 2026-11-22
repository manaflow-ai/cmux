// The Messages page's host bridge (`cmux.home.messages.*`, HomeMessagesPage.swift): what only the
// app knows or does. The conversations themselves come from the daemon through the Channels data
// layer; the host adds
// - `menu {kind, conversation?}`: a row's catalog items (Group Info, Mute, Rename, Add People, Leave,
//   Chat Colors…, a Chief's Usage, Import Memories, Archive and Delete) or the compose button's
//   (New Message, New Chief, New Channel, Invite, Show Hidden Conversations, the teams), each with
//   the registry's own title;
// - `perform {action, arguments}`: runs one of them through the action registry, as the palette and
//   the CLI do (the person's click only; Delete Conversation… asks first, natively);
// - the `chrome` stream: the window's traffic lights over the page's top-left, so the list's header
//   and the compose button keep clear of them.
// In a browser (no host) there are no host items and no lights.
import type { PageClient } from "../shared/pageClient";
import type { HostMenuItem, MessagesChrome, MessagesHost } from "./types";

export const MessagesOps = {
  menu: "cmux.home.messages.menu",
  perform: "cmux.home.messages.perform",
  chrome: "cmux.home.messages.chrome",
} as const;

/** The bridge over the app's page client. */
export function pageMessagesHost(client: PageClient): MessagesHost {
  return {
    async menu(kind, conversation) {
      try {
        const answer = await client.call<{ items?: HostMenuItem[] }>(MessagesOps.menu, {
          kind,
          ...(conversation ? { conversation } : {}),
        });
        return Array.isArray(answer?.items) ? answer.items.filter(isMenuItem) : [];
      } catch {
        // An older host without the op: the list's own items only.
        return [];
      }
    },
    async perform(item) {
      // A refusal (no click behind it, an action the host no longer offers) changes nothing.
      await client.call(MessagesOps.perform, { action: item.action, arguments: item.arguments ?? {} }).catch(() => {});
    },
    subscribeChrome(listener) {
      let stop: (() => void) | undefined;
      let ended = false;
      void client
        .subscribe<MessagesChrome>(MessagesOps.chrome, (data) => listener(chromeOf(data)))
        .then((unsubscribe) => {
          if (ended) unsubscribe();
          else stop = unsubscribe;
        })
        .catch(() => {});
      return () => {
        ended = true;
        stop?.();
      };
    },
  };
}

/** No host: a browser or the gallery without one. */
export const noMessagesHost: MessagesHost = {
  menu: async () => [],
  perform: async () => {},
  subscribeChrome: () => () => {},
};

function isMenuItem(value: unknown): value is HostMenuItem {
  const item = value as HostMenuItem | null;
  return !!item && typeof item.id === "string" && typeof item.title === "string" && typeof item.action === "string";
}

function chromeOf(data: MessagesChrome | null | undefined): MessagesChrome {
  const lights = data?.windowControls;
  const valid =
    lights &&
    [lights.x, lights.y, lights.width, lights.height].every((n) => typeof n === "number" && Number.isFinite(n));
  const color = data?.unreadColor;
  return {
    windowControls: valid ? lights : null,
    ...(typeof color === "string" && /^#[0-9a-f]{6}$/i.test(color) ? { unreadColor: color } : {}),
  };
}

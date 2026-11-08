// The part of a message the pointer is on when the native context menu opens (cx-2lm4): a code
// block, a command and its output, a file path or a web link. The message menu reports it
// (messageMenu.ts) and the host adds the part's own items above the message's: Copy Code, Copy
// Command and Copy Output, Open and Copy Path, Open Link and Copy Link. Long texts (code, command
// output) stay off the DOM: a view registers its part on its element with `menuPartRef`.
//
// A chat the transcript opens on a click (a started chat's card or chip, a sub-session's card, a
// message's sender, a task line: `data-open-session`) is a `session` part: the click opens it on the
// right (`chat.offer.open`), and the menu offers Open on Right and, when a tab already shows it, Go
// to Chat (Leo, ask-e9c4803262: "right split is fine on click by default ... and you can right click
// to go to it"), then the chat's sidebar row's menu (the Priority row's catalog rows on that chat; Leo,
// 2026-11-05: "right clicking on a deeplink/link to another session/name of another session/rendering
// of it shuold give thes options"). An agent link that opens a chat is both: its link rows stay.

export type MenuPart = {
  code?: string;
  command?: string;
  output?: string;
  path?: string;
  link?: string;
  /// The chat a click on this element opens (`data-open-session`).
  session?: string;
  /// That chat is a message's sender (`data-open-session-sender`): `chat.offer.open`'s `sender`.
  sender?: true;
};

/// The attributes that make an element a `session` part: the chat `sessionId` its click opens, and
/// `sender` for a message's sender.
export type OpenSessionAttributes = { "data-open-session": string; "data-open-session-sender"?: string };
export const openSessionAttributes = (sessionId: string, sender = false): OpenSessionAttributes =>
  sender ? { "data-open-session": sessionId, "data-open-session-sender": "" } : { "data-open-session": sessionId };

const parts = new WeakMap<Element, MenuPart>();

/// A ref callback that registers `part` on the element it is set on.
export function menuPartRef(part: MenuPart) {
  return (element: Element | null) => {
    if (element) parts.set(element, part);
  };
}

/// The innermost part around `target`: a registered element, a path chip or file row
/// (`data-path`), a chat a click opens (`data-open-session`) or an http(s) link. Undefined elsewhere.
export function menuPartAt(target: Element | null): MenuPart | undefined {
  for (let element = target; element; element = element.parentElement) {
    const part = parts.get(element);
    if (part) return part;
    const path = element.getAttribute("data-path");
    if (path) return { path };
    const session = element.getAttribute("data-open-session");
    if (session) {
      // An agent link that opens the reader's chat keeps its link rows (Open Link, Copy Link) too.
      const link =
        element instanceof HTMLAnchorElement && /^https?:\/\//i.test(element.href) ? element.href : undefined;
      return {
        session,
        ...(element.hasAttribute("data-open-session-sender") ? { sender: true as const } : {}),
        ...(link ? { link } : {}),
      };
    }
    if (element instanceof HTMLAnchorElement && /^https?:\/\//i.test(element.href)) return { link: element.href };
  }
  return undefined;
}

// The page's own routes (hash routes next to `#/conversation/<id>[/message/<id>]`, which stays as it
// is): each opens one sheet the page draws over the daemon's operations. A host (the docked Home)
// only sets the hash; the "+" button and the palette set the same hash, so a plain browser works
// the same with no host.
//   #/new/message                  a new message or channel: people and Chiefs, an optional title
//   #/new/chief                    a new Chief
//   #/conversation/<id>/invite     add people or Chiefs to a conversation
//   #/chief/<agent>/edit           edit a Chief's profile
//   #/chief/<agent>/archive        archive (delete) a Chief, after a confirmation

export type HomeRoute =
  | { kind: "newMessage" }
  | { kind: "newChief" }
  | { kind: "invite"; conversation: string }
  | { kind: "editChief"; chief: string }
  | { kind: "archiveChief"; chief: string };

const ID = "[A-Za-z0-9_-]+";
const PATTERNS: readonly [RegExp, (match: RegExpExecArray) => HomeRoute][] = [
  [/^#\/new\/message\/?$/, () => ({ kind: "newMessage" })],
  [/^#\/new\/chief\/?$/, () => ({ kind: "newChief" })],
  [new RegExp(`^#/conversation/(${ID})/invite/?$`), (m) => ({ kind: "invite", conversation: m[1]! })],
  [new RegExp(`^#/chief/(${ID})/edit/?$`), (m) => ({ kind: "editChief", chief: m[1]! })],
  [new RegExp(`^#/chief/(${ID})/archive/?$`), (m) => ({ kind: "archiveChief", chief: m[1]! })],
];

/** The sheet route a page URL's hash names, if any. */
export function parseRoute(hash: string): HomeRoute | undefined {
  for (const [pattern, route] of PATTERNS) {
    const match = pattern.exec(hash);
    if (match) return route(match);
  }
  return undefined;
}

/** The hash of a route. */
export function routeHash(route: HomeRoute): string {
  switch (route.kind) {
    case "newMessage":
      return "#/new/message";
    case "newChief":
      return "#/new/chief";
    case "invite":
      return `#/conversation/${route.conversation}/invite`;
    case "editChief":
      return `#/chief/${route.chief}/edit`;
    case "archiveChief":
      return `#/chief/${route.chief}/archive`;
  }
}

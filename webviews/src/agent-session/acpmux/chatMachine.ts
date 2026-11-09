// Where a chat's agent process runs: the one answer every surface that names a chat's machine draws
// (Session Info's Environment, web and native, and its Save), so they cannot drift apart. The chat
// runs on this Mac only when its daemon is this Mac's and acpmux names no peer for it; a peer's chat,
// a Cloud machine's or one reached over the app's wire to another machine names that machine (Leo,
// 2026-11-07, on a huge-blue chat whose Session Info said "cosmic-gray · Local": "hmm is the session
// info not accurately describing machine provenance?").
import type { AcpmuxSnapshot } from "./model";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

export type ChatMachineKind = "local" | "ssh" | "cloud";

export type ChatMachine = { icon: string; name?: string; kind: ChatMachineKind };

/// What the page knows of its route to the chat beyond the chat's summary (`chatPlace`).
export type ChatPlace = {
  /// The connection's origin as acpmux named it (`AcpmuxSnapshot.origin`): `remote` and `peer` are
  /// a daemon on another machine than this Mac (the app's wire to a chat elsewhere, a browser).
  origin?: AcpmuxSnapshot["origin"];
  /// The app's wire reaches the person's own Cloud machine (`AcpmuxSnapshot.ownerCloud`).
  ownerCloud?: boolean;
};

/// The chat's place from the pane's snapshot: its origin and whether it is an owned Cloud machine.
/// O(1): the peer is the summary's own (direct.ts `attachedDetail` keeps it through an attach).
export function chatPlace(snapshot: Pick<AcpmuxSnapshot, "origin" | "ownerCloud">): ChatPlace {
  return {
    ...(snapshot.origin ? { origin: snapshot.origin } : {}),
    ...(snapshot.ownerCloud ? { ownerCloud: true } : {}),
  };
}

/// Where the chat's agent runs, as the composer's computer chip names it (ComposerContext computerId):
/// a peer (by its name in `acpmux host ls`, as the tab title names it) or a Cloud host is another
/// machine; a chat on the daemon a remote route reaches is that daemon's machine (acpmux `machine`,
/// its own hostname); else it is this Mac by its name (`machineName`). With no name known (an older
/// App), the row says nothing rather than a generic "This computer".
export function chatMachine(
  summary: Pick<Summary, "peer" | "host" | "hostKind" | "machine"> | undefined,
  machineName: string | undefined,
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>,
  place?: ChatPlace,
): ChatMachine {
  const peer = summary?.peer;
  const elsewhere = place?.origin === "remote" || place?.origin === "peer";
  if (summary?.hostKind === "cloud" || (peer && peerKinds?.[peer] === "cloud"))
    return { icon: "cloud", name: summary?.host || peer || machineName, kind: "cloud" };
  if (peer) return { icon: "machine.remote", name: summary?.host || peer, kind: "ssh" };
  // The page's own acpmux is another machine's (the app's wire to it): the chat runs there, named by
  // that daemon (acpmux `machine`), never on this Mac.
  if (elsewhere) {
    const name = summary?.machine || summary?.host || undefined;
    return place?.ownerCloud ? { icon: "cloud", name, kind: "cloud" } : { icon: "machine.remote", name, kind: "ssh" };
  }
  return { icon: "machine.mac", name: machineName || summary?.host || undefined, kind: "local" };
}

/// Whether the chat's folders are this Mac's, so Open Folder, a source file and a subagent's changes
/// open here: `chatMachine` says Local, and no host not marked local names another machine
/// (sessionList.ts `cloudHost`). A chat with no summary yet is not.
export function chatOnThisMac(
  summary: Pick<Summary, "peer" | "host" | "hostKind" | "machine"> | undefined,
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>,
  place?: ChatPlace,
): boolean {
  if (!summary || (summary.host && summary.hostKind !== "local")) return false;
  return chatMachine(summary, undefined, peerKinds, place).kind === "local";
}

/// The composer's computer id for the chat (ComposerContext): its peer, its Cloud host, else `local`,
/// the page's own acpmux, which is this Mac or, over a remote route, the machine that route reaches.
export function chatComputerId(summary: Pick<Summary, "peer" | "host" | "hostKind"> | undefined): string {
  return summary?.peer || (summary?.hostKind === "cloud" && summary.host) || "local";
}

/// What the composer's `local` row is called: the page's own acpmux by name. Over a remote route
/// (origin `remote` or `peer`) that is the machine the route reaches, as `chatMachine` names it, never
/// this Mac; else this Mac's name (`localName`).
export function ownMachineName(
  summary: Pick<Summary, "peer" | "host" | "hostKind" | "machine"> | undefined,
  localName: string | undefined,
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>,
  place?: ChatPlace,
): string | undefined {
  const elsewhere = place?.origin === "remote" || place?.origin === "peer";
  if (!elsewhere) return localName;
  // The chat's own machine is the page's acpmux only when it runs there (no peer, no Cloud host).
  const own =
    summary && chatComputerId(summary) === "local" ? chatMachine(summary, undefined, peerKinds, place) : undefined;
  return own?.name || localName;
}

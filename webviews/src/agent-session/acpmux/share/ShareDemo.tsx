// l10n-allow-file: gallery demo (made-up chat and people), not shipped UI.
// The gallery's chat header (who else is here, then the ••• menu's tools as they are; Share… lives
// in that menu), the Share dialog open on a fixture, and the copied-link toast (Share.gallery.ts). The fixture host answers `share.op` from memory, so every
// step in the dialog works in the gallery the way it does against the daemon.
import { useEffect, useState } from "react";
import { PresenceStack } from "../multiplayer/Faces";
import type { Participant } from "../multiplayer/participants";
import { ShareDialogHost, shareToasts } from "./ShareControl";
import { shareView, type ChatShare, type ShareCall } from "./shareState";
import "../header/header.css";

export type ShareDemoProps = {
  viewing: Participant[];
  shares: ChatShare[];
  /** Draw the dialog open. */
  open?: boolean;
  /** Show the copied-link toast. */
  toast?: "public" | "invite";
  /** The chat's title (default: a short one). */
  chat?: string;
  /** The host refuses every read with this code (the error line on open). */
  fail?: string;
  /** A look the gallery compares with the shipped sheet (Share.gallery.css); none is the shipped one. */
  look?: "two-primaries" | "popover" | "outline" | "row-hover" | "row-filled" | "row-bleed";
  /** The daemon does not answer the dialog's read: it reads again on its own and says Still reading. */
  unread?: boolean;
};

function fixtureHost(shares: ChatShare[], fail?: string, unread = false): ShareCall {
  let next = shares.map((share) => ({ ...share }));
  return async (op, params = {}) => {
    if (fail) throw Object.assign(new Error(fail), { code: fail });
    if (op === "state" && unread) throw new Error("share: 503 Service Unavailable");
    if (op === "state") return { shares: next };
    if (op === "link") {
      const made: ChatShare = { ...LINK, shareId: `demo-${next.length}`, createdAt: Date.now() };
      next = [...next, made];
      return { shareId: made.shareId, url: "https://share.example.com/g/demo#secret", expiresAt: made.expiresAt };
    }
    if (op === "revoke") next = next.filter((share) => share.shareId !== params.shareId);
    return {};
  };
}

const LINK: ChatShare = {
  shareId: "demo-link",
  state: "active",
  url: null,
  inviteUrl: "https://share.example.com/i/demo-link",
  role: "view",
  createdAt: 0,
  expiresAt: 0,
  usesLeft: 1000,
  guests: [],
  invitees: [],
};

export function ShareDemo({
  viewing,
  shares,
  open = false,
  toast,
  fail,
  unread,
  look,
  chat = "Add retries to the uploader",
}: ShareDemoProps) {
  const [call] = useState(() => fixtureHost(shares, fail, unread));
  const [shown, setShown] = useState(open);
  // The dialog portals out of this tree, so the look is on the root.
  useEffect(() => {
    if (!look) return;
    document.documentElement.dataset.shareLook = look;
    return () => {
      delete document.documentElement.dataset.shareLook;
    };
  }, [look]);
  useEffect(() => {
    if (!toast) return;
    const id = shareToasts.show({
      id: "share.copied",
      duration: 0,
      title: toast === "public" ? "Public link copied" : "Invite link copied",
      message:
        toast === "public"
          ? "Signed-in people can send messages; others can view."
          : "Only people with access can open it",
      actions: [{ id: "manage", label: "Manage links" }],
    });
    return () => shareToasts.close(id);
  }, [toast]);
  return (
    <div className="acpmux-root" style={{ padding: 16, minHeight: 520 }}>
      <header className="acpmux-header">
        <strong style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {chat}
        </strong>
        <div className="acpmux-handoff-header-tools">
          <PresenceStack viewing={viewing} />
          <ShareDialogHost
            sessionId="demo"
            chat={chat}
            open={shown}
            onOpenChange={setShown}
            call={call}
            initial={shareView(shares)}
          />
        </div>
      </header>
    </div>
  );
}

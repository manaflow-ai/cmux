// l10n-allow-file: gallery demo (made-up chat and people), not shipped UI.
// The gallery's header row with who is here and Share (Share.gallery.ts), its dialog open on a
// fixture, and the copied-link toast. The fixture host answers `share.op` from memory, so every
// step in the dialog works in the gallery the way it does against the daemon.
import { useEffect, useState } from "react";
import { PresenceStack } from "../multiplayer/Faces";
import type { Participant } from "../multiplayer/participants";
import { ShareButton, shareToasts, type ShareLook } from "./ShareControl";
import { shareView, type ChatShare, type ShareCall } from "./shareState";
import "../header/header.css";

export type ShareDemoProps = {
  look: ShareLook;
  viewing: Participant[];
  shares: ChatShare[];
  /** Draw the dialog open. */
  open?: boolean;
  /** Show the copied-link toast. */
  toast?: "public" | "invite";
};

function fixtureHost(shares: ChatShare[]): ShareCall {
  let next = shares.map((share) => ({ ...share }));
  return async (op, params = {}) => {
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

export function ShareDemo({ look, viewing, shares, open = false, toast }: ShareDemoProps) {
  const [call] = useState(() => fixtureHost(shares));
  useEffect(() => {
    if (!toast) return;
    const id = shareToasts.show({
      id: "share.copied",
      duration: 0,
      title: toast === "public" ? "Public link copied" : "Invite link copied",
      message: toast === "public" ? "Anyone with the link can view this chat." : "Only people with access can open it",
      actions: [{ id: "manage", label: "Manage links" }],
    });
    return () => shareToasts.close(id);
  }, [toast]);
  return (
    <div className="acpmux-root" style={{ padding: 16, minHeight: 520 }}>
      <header className="acpmux-header">
        <strong style={{ flex: 1 }}>Add retries to the uploader</strong>
        <div className="acpmux-handoff-header-tools">
          <PresenceStack viewing={viewing} />
          <ShareButton
            sessionId="demo"
            chat="Add retries to the uploader"
            look={look}
            call={call}
            initial={open ? shareView(shares) : undefined}
          />
        </div>
      </header>
    </div>
  );
}

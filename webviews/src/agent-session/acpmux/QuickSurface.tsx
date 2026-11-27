import type React from "react";
import { FloatingCompactBar, FloatingHeader } from "./FloatingChat";
import { useFloatingKeys, type QuickFloating } from "./floatingChatModel";
import { useEffect, useState } from "react";
import { QuickKeyHints } from "./QuickKeyHints";
import { ChiefDock, type ChiefDockProps } from "./ChiefDock";
import { bottomStackBox, reportToastAvoidance } from "./toastAvoidance";

/// The panel's bottom stack: its direct children under the thread (permission and trust asks, the
/// composer, the key hints). The floating header, the thread and the Chief Dock (drawn over the
/// panel on its own) are not part of it.
const QUICK_NOT_STACK = ":is(.acpmux-floating-header, .acpmux-quick-thread, .acpmux-chief-dock)";
const quickBottomStack = (root: HTMLElement) => bottomStackBox(root, QUICK_NOT_STACK);

/// The Quick Composer panel's page: the composer filling the panel, and once the chat has a
/// first prompt its transcript above, scrolling within what the panel leaves it. No session
/// list, header, hero or recent chats: the panel is for one quick prompt and its reply. As the
/// floating chat (cx-b9qi) it holds a running chat: a header with its title and controls, or,
/// folded, only the compact bar.
export function QuickSurface({
  transcript,
  asks,
  composer,
  floating,
  chiefDock,
}: {
  /// The chat's transcript, once there is one.
  transcript?: React.ReactNode;
  /// Permission and folder-trust asks, between the transcript and the composer.
  asks?: React.ReactNode;
  composer: React.ReactNode;
  /// The floating chat around the page, when the panel holds the chat.
  floating?: QuickFloating;
  /// The optional Chief Dock, enabled by the named experiment while the design is dogfooded.
  chiefDock?: ChiefDockProps;
}) {
  useFloatingKeys(floating);
  const holding = floating?.state.holding === true;
  const [root, setRoot] = useState<HTMLDivElement | null>(null);
  // The panel is a bottom-aligned column, so its asks and composer rest at its foot, where the app's
  // toasts rest, with or without a thread above: the app's toasts lift above the whole stack and
  // never cover it (toastAvoidance.ts), and the composer never moves for them.
  useEffect(() => (root ? reportToastAvoidance(root, quickBottomStack) : undefined), [root]);
  if (floating && holding && floating.state.collapsed)
    return (
      <div className="acpmux-quick" data-floating="compact">
        <div className="acpmux-quick-compact-bar">
          <FloatingCompactBar floating={floating} />
        </div>
        {chiefDock && <ChiefDock {...chiefDock} />}
      </div>
    );
  return (
    <div
      ref={setRoot}
      className="acpmux-quick"
      data-has-transcript={transcript ? "" : undefined}
      data-floating={holding ? "open" : undefined}
    >
      {floating && holding && <FloatingHeader floating={floating} />}
      {transcript && <div className="acpmux-quick-thread">{transcript}</div>}
      {asks}
      {composer}
      <QuickKeyHints floating={holding} />
      {chiefDock && <ChiefDock {...chiefDock} />}
    </div>
  );
}

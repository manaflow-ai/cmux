import type React from "react";
import { FloatingCompactBar, FloatingHeader, useFloatingKeys, type QuickFloating } from "./FloatingChat";
import { QuickKeyHints } from "./QuickKeyHints";
import { ChiefDock, type ChiefDockProps } from "./ChiefDock";

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

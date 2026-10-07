import React from "react";
import { QuickKeyHints } from "./QuickKeyHints";

/// The Quick Composer panel's page: the composer filling the panel, and once the chat has a
/// first prompt its transcript above, scrolling within what the panel leaves it. No session
/// list, header, hero or recent chats: the panel is for one quick prompt and its reply.
export function QuickSurface({
  transcript,
  asks,
  composer,
}: {
  /// The chat's transcript, once there is one.
  transcript?: React.ReactNode;
  /// Permission and folder-trust asks, between the transcript and the composer.
  asks?: React.ReactNode;
  composer: React.ReactNode;
}) {
  return (
    <div className="acpmux-quick" data-has-transcript={transcript ? "" : undefined}>
      {transcript && <div className="acpmux-quick-thread">{transcript}</div>}
      {asks}
      {composer}
      <QuickKeyHints />
    </div>
  );
}

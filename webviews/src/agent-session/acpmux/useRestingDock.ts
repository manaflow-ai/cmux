// The bottom stack's reach at rest, for the prompt rail's box (VirtualTranscript `railBox`): its
// smallest at the view's height. Kept outside the transcript's render so the React Compiler sees no
// ref read or written there.
import { useState } from "react";

/// The stack's smallest space over the view's foot since the view took `height` in chat `sessionId`
/// with stack `dock`: a new height, chat or stack starts over (another stack from none, since its
/// first measure comes in the layout effect after this render). 0 while that stack is not measured.
export function useRestingDock(
  height: number,
  sessionId: string | undefined,
  dock: HTMLElement | null | undefined,
  dockSpace: number,
): number {
  const [rest] = useState(() => new RestingDock());
  return rest.space(height, sessionId, dock, dockSpace);
}

class RestingDock {
  private height = -1;
  private sessionId: string | undefined;
  private dock: HTMLElement | null | undefined;
  private rest = 0;

  space(
    height: number,
    sessionId: string | undefined,
    dock: HTMLElement | null | undefined,
    dockSpace: number,
  ): number {
    if (this.dock !== dock) this.reset(height, sessionId, dock, 0);
    else if (this.height !== height || this.sessionId !== sessionId) this.reset(height, sessionId, dock, dockSpace);
    else if (dockSpace > 0 && (this.rest <= 0 || dockSpace < this.rest)) this.rest = dockSpace;
    return this.rest;
  }

  private reset(height: number, sessionId: string | undefined, dock: HTMLElement | null | undefined, space: number) {
    this.height = height;
    this.sessionId = sessionId;
    this.dock = dock;
    this.rest = space;
  }
}

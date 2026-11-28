// View state of one mounted diff pane: the session plus the comment target
// line, an armed destructive button, and the embed in use.

import type { EmbedCreateResult } from "../interfaces/embed.ts"
import type { Session } from "../session.ts"

export interface Target {
  path: string
  line: number
  side: "old" | "new"
}

export interface PaneView {
  session: Session
  target: () => Target | null
  setTarget(t: Target | null): void
  isTarget(path: string, line: number, side: "old" | "new"): boolean
  /** Hunk or file id whose destructive button needs a second tap. */
  armed: () => string | null
  setArmed(id: string | null): void
  /** App that renders embeds in this pane ("Shown with …"), or null for the built-in diff. */
  embedApp: () => string | null
  noteEmbed(r: EmbedCreateResult): void
}

export function createPaneView(session: Session): PaneView {
  const [target, setTarget] = signal<Target | null>(null)
  const [armed, setArmed] = signal<string | null>(null)
  const [embedApp, setEmbedApp] = signal<string | null>(null)
  return {
    session,
    target,
    setTarget: (next) => setTarget(next),
    isTarget: (path, line, side) => {
      const tg = target()
      return !!tg && tg.path === path && tg.line === line && tg.side === side
    },
    armed,
    setArmed: (id) => setArmed(id),
    embedApp,
    noteEmbed: (r) => setEmbedApp(r.app)
  }
}

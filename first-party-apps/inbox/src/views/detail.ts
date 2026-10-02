/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The selected item in full: kind, title, context, actions, quick reply.
// Used by the focus (list + detail) and card variants. Signals and effects
// are created once per variant mount; the dynamic children below only build
// views, so nothing leaks when the selection changes.

import { markDone, openItem, reply, step } from "../actions.ts"
import { t } from "../l10n.ts"
import type { ViewItem } from "../model.ts"
import { current, now, replyBlocked } from "../store.ts"
import { ago } from "../time.ts"
import { itemContext, kindLabel, kindSymbol, kindTint, snoozeMenu } from "./parts.ts"

export interface DetailState {
  item: () => ViewItem | null
  id: () => string | null
  /** Whether an item is selected (changes only between none and some). */
  has: () => boolean
  isAgent: () => boolean
  context: () => string | null
  hasContext: () => boolean
  draft: () => string
  setDraft: (v: string) => void
}

/** Creates the detail's signals; call once from a variant's render. */
export function detailState(): DetailState {
  const id = computed(() => current()?.id ?? null)
  const has = computed(() => id() !== null)
  const isAgent = computed(() => current()?.source === "agent")
  const [draft, setDraft] = signal("")
  const context = itemContext(current)
  const hasContext = computed(() => !!context())
  return { item: current, id, has, isAgent, context, hasContext, draft, setDraft }
}

// Live props may run once more while the selection clears; they read a blank item then.
const BLANK: ViewItem = { id: "", source: "notification", kind: "notification", title: "", detail: "", at: 0, unreadHint: false, mine: false, notifications: [], unread: false, snoozedUntil: null, workspace: null }
const get = (s: DetailState) => s.item() ?? BLANK
const act = (s: DetailState, fn: (i: ViewItem) => unknown) => () => {
  const i = s.item()
  return i ? fn(i) : undefined
}

/** Open, Done, Snooze, and Skip when `withSkip`. */
export function Actions(s: DetailState, withSkip: boolean): CmuxView {
  return HStack({ spacing: 8 }, [
    Button(t("action.open", "Open"), act(s, openItem)),
    Button(t("action.doneShort", "Done"), act(s, (i) => markDone([i]))),
    snoozeMenu(() => (s.item() ? [s.item()!] : [])),
    Spacer(),
    withSkip ? Button(t("action.skip", "Skip"), () => step(1, s.id())) : null
  ])
}

/** A reply field for agents, or why it is not available. */
export function ReplyField(s: DetailState): CmuxView {
  return Group([
    () => {
      if (!s.isAgent()) return null
      if (replyBlocked()) return Text(t("reply.needsScope", "Quick reply needs permission to type into terminals (Settings > Apps > Inbox).")).font("caption").color("tertiary").lineLimit(3)
      return TextField(s.draft, {
        placeholder: t("action.reply", "Reply…"),
        onEdit: (text) => s.setDraft(text),
        onSubmit: (text) => act(s, (i) => reply(i, text).then((ok) => ok && s.setDraft("")))()
      })
    }
  ])
}

/** Kind, title, detail and context of the selected item. */
export function Summary(s: DetailState, titleFont: string): CmuxView {
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      Icon(() => kindSymbol(get(s))).color(() => kindTint(get(s))).font("caption"),
      Text(() => kindLabel(get(s).kind)).font("caption").color("secondary"),
      Text(() => get(s).workspace?.name ?? "").font("caption").color("tertiary").lineLimit(1),
      Spacer(),
      Text(() => ago(get(s).at, now())).font("caption").color("tertiary")
    ]),
    Text(() => get(s).title).font(titleFont).lineLimit(4),
    Text(() => get(s).detail).font("callout").color("secondary").lineLimit(2),
    () =>
      s.hasContext()
        ? Text(s.context)
            .font("caption")
            .monospaced()
            .color("secondary")
            .lineLimit(10)
            .padding(8)
            .frame({ maxWidth: "infinity" })
            .background("hover")
            .cornerRadius(6)
        : null
  ])
}

/** The full detail area, or a hint when nothing is selected. */
export function Detail(s: DetailState): CmuxView {
  return Group([
    () =>
      s.has()
        ? VStack({ spacing: 12 }, [Summary(s, "headline"), Actions(s, false), ReplyField(s)])
        : Text(t("detail.none", "Select an item")).font("callout").color("tertiary").padding(12)
  ])
}

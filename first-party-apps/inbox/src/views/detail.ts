/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The selected item in full: kind, title, body, the response controls a
// request asks for, and the item's actions. Used by the focus and card
// variants. Signals are created once per variant mount; the dynamic children
// below only build views, so nothing leaks when the selection changes.

import { markDone, openItem, respond, runAction, step } from "../actions.ts"
import type { FeedItem, ResponseSchema } from "../feed.ts"
import { t } from "../l10n.ts"
import { current } from "../store.ts"
import { ago } from "../time.ts"
import { itemSymbol, itemTint, kindLabel, snoozeMenu } from "./parts.ts"

export interface DetailState {
  item: () => FeedItem | null
  /** The selected item without subscribing (dynamic children rebuild on `form`, not on every list change). */
  peek: () => FeedItem | null
  id: () => string | null
  has: () => boolean
  /** Changes only when the selected item's response form changes. */
  form: () => string
  hasBody: () => boolean
  draft: () => string
  setDraft: (v: string) => void
}

const formKey = (i: FeedItem | null) => (i ? `${i.id}:${i.needsResponse ? (i.response?.type ?? "none") : "none"}` : "")

/** Creates the detail's signals; call once from a variant's render. */
export function detailState(): DetailState {
  let latest: FeedItem | null = null
  // Subscribed before `form`, so it updates first in a flush.
  effect(() => {
    latest = current()
  })
  const id = computed(() => current()?.id ?? null)
  const has = computed(() => id() !== null)
  const form = computed(() => formKey(current()))
  const hasBody = computed(() => !!current()?.body)
  const [draft, setDraft] = signal("")
  return { item: current, peek: () => latest, id, has, form, hasBody, draft, setDraft }
}

// Live props may run once more while the selection clears; they read a blank item then.
const BLANK: FeedItem = {
  id: "",
  kind: "notify",
  title: "",
  urgency: "normal",
  needsResponse: false,
  source: { kind: "app", id: "", name: "" },
  subject: {},
  status: "open",
  snoozedUntil: null,
  seenAt: null,
  createdAt: "",
  updatedAt: "",
  revision: "",
  expiresAt: null,
  actions: []
}
const get = (s: DetailState) => s.item() ?? BLANK
const act = (s: DetailState, fn: (i: FeedItem) => unknown) => () => {
  const i = s.item()
  return i ? fn(i) : undefined
}

/** The controls a request's response schema asks for. Taps call `feed.respond` synchronously (origin `user`). */
function responseControls(s: DetailState, schema: ResponseSchema): CmuxView | null {
  const answer = (value: unknown) => act(s, (i) => respond(i, value))
  switch (schema.type) {
    case "choice":
      return VStack(
        { spacing: 4 },
        schema.options.map((o) => {
          const b = Button(o.label, answer({ choice: o.value }))
          return o.destructive ? b.destructive() : b
        })
      )
    case "approve":
      return HStack({ spacing: 8 }, [Button(t("respond.approve", "Approve"), answer({ approved: true })), Button(t("respond.deny", "Deny"), answer({ approved: false })).destructive(), Spacer()])
    case "confirm":
      return HStack({ spacing: 8 }, [Button(t("respond.confirm", "Confirm"), answer({ confirmed: true })), Button(t("respond.cancel", "Cancel"), answer({ confirmed: false })), Spacer()])
    case "text":
      return TextField(s.draft, {
        placeholder: schema.placeholder ?? t("respond.placeholder", "Answer…"),
        onEdit: (text) => s.setDraft(text),
        onSubmit: (text) =>
          act(s, (i) => {
            if (!text.trim()) return undefined
            s.setDraft("")
            return respond(i, { text: text.trim() })
          })()
      })
    case "external":
      // Sign-in and passkey: the user completes it in the agent's browser tab; the agent resumes after.
      return VStack({ spacing: 6 }, [
        Button(t("respond.continueInBrowser", "Continue in Browser"), act(s, openItem)),
        Text(t("respond.externalHelp", "Finish it in the browser tab that opens next to this one. The agent continues after; it never sees the credential."))
          .font("caption")
          .color("tertiary")
          .lineLimit(3)
      ])
  }
}

/** The response form of the selected request, rebuilt only when the form changes. */
export function ResponseForm(s: DetailState): CmuxView {
  return Group([
    () => {
      s.form()
      const i = s.peek()
      return i?.needsResponse && i.response ? responseControls(s, i.response) : null
    }
  ])
}

/** Open, Done, Snooze, the item's custom actions, and Skip when `withSkip`. */
export function Actions(s: DetailState, withSkip: boolean): CmuxView {
  return HStack({ spacing: 8 }, [
    // A sign-in or passkey request opens through its response form ("Continue in Browser").
    Group([() => (s.form() && s.peek()?.open && s.peek()?.response?.type !== "external" ? Button(t("action.open", "Open"), act(s, openItem)) : null)]),
    Button(t("action.doneShort", "Done"), act(s, (i) => markDone([i]))),
    snoozeMenu(() => (s.item() ? [s.item()!] : [])),
    Group([
      () => {
        s.form()
        const custom = (s.peek()?.actions ?? []).filter((a) => a.kind === "custom")
        return custom.length ? Menu(t("action.more", "More"), custom.map((a) => Button(a.title, act(s, (i) => runAction(i, a))))) : null
      }
    ]),
    Spacer(),
    withSkip ? Button(t("action.skip", "Skip"), () => step(1, s.id())) : null
  ])
}

/** Kind, source, title and body of the selected item. */
export function Summary(s: DetailState, titleFont: string): CmuxView {
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      Icon(() => itemSymbol(get(s))).color(() => itemTint(get(s))).font("caption"),
      Text(() => [kindLabel(get(s)), get(s).source.name, get(s).subject.workspaceName].filter(Boolean).join(" · ")).font("caption").color("secondary").lineLimit(1),
      Spacer(),
      Text(() => (get(s).updatedAt ? ago(Date.parse(get(s).updatedAt), Date.now()) : "")).font("caption").color("tertiary")
    ]),
    Text(() => get(s).title).font(titleFont).lineLimit(4),
    () =>
      s.hasBody()
        ? Text(() => get(s).body ?? "")
            .font("callout")
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
        ? VStack({ spacing: 12 }, [Summary(s, "headline"), ResponseForm(s), Actions(s, false)])
        : Text(t("detail.none", "Select an item")).font("callout").color("tertiary").padding(12)
  ])
}

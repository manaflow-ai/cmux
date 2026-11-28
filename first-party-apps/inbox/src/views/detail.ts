/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The selected item in full: kind, title, body, the answer form its kind asks
// for, and the triage actions it allows. Used by the focus and card variants.
// Signals are created once per variant mount; the dynamic children rebuild
// only when the selected item's form changes, so drafts survive list updates.

import { answer, decline, markDone, openItem, step, unarchive } from "../actions.ts"
import { answerButtons, approveAnswer, choiceAnswer, choiceComplete, fieldsAnswer, formOf, openButtons, toggleOption, type ChoiceQuestion, type Field, type Form } from "../answers.ts"
import { isOpenRequest, type FeedItem } from "../feed.ts"
import { t } from "../l10n.ts"
import { ago } from "../time.ts"
import { itemSymbol, itemTint, kindLabel, snoozeMenu } from "./parts.ts"

export interface DetailState {
  item: () => FeedItem | null
  /** The selected item without subscribing (dynamic children rebuild on `form`, not on every list change). */
  peek: () => FeedItem | null
  id: () => string | null
  has: () => boolean
  /** Changes only when the selected item or its form changes. */
  form: () => string
  drafts: () => Record<string, unknown>
  setDraft: (key: string, value: unknown) => void
  workspace: (id: string | undefined) => string
}

const formKey = (i: FeedItem | null) => (i ? `${i.id}:${i.state}:${i.archived_at === null ? "active" : "done"}` : "")

/** Creates the detail's signals; call once from a variant's render. */
export function detailState(current: () => FeedItem | null, workspace: (id: string | undefined) => string): DetailState {
  let latest: FeedItem | null = null
  // Subscribed before `form`, so it updates first in a flush.
  effect(() => {
    latest = current()
  })
  const id = computed(() => current()?.id ?? null)
  const form = computed(() => formKey(current()))
  const [drafts, setDrafts] = signal<Record<string, unknown>>({})
  let draftsFor = ""
  effect(() => {
    const key = form()
    if (key !== draftsFor) {
      draftsFor = key
      setDrafts({})
    }
  })
  return {
    item: current,
    peek: () => latest,
    id,
    has: computed(() => id() !== null),
    form,
    drafts,
    setDraft: (key, value) => setDrafts((d) => ({ ...d, [key]: value })),
    workspace
  }
}

const act = (s: DetailState, fn: (i: FeedItem) => unknown) => () => {
  const i = s.peek()
  return i ? fn(i) : undefined
}
const reply = (s: DetailState, value: unknown) => act(s, (i) => answer(i, value))

const caption = (text: string) => Text(text).font("caption").color("secondary").lineLimit(6)
const option = (label: string, on: () => boolean, tap: () => unknown) =>
  Button(label, tap)
    .padding({ top: 3, bottom: 3, leading: 8, trailing: 8 })
    .background(() => (on() ? "selected" : null))
    .cornerRadius(6)

function choiceControls(s: DetailState, questions: ChoiceQuestion[], oneTap: boolean): CmuxView {
  if (oneTap) {
    const q = questions[0]!
    return VStack({ spacing: 4 }, [caption(q.question), ...q.options.map((o) => Button(o.label, reply(s, { answers: { [q.id]: { selected: [o.id] } } })).help(o.description ?? o.label))])
  }
  const selected = () => (s.drafts().selected ?? {}) as Record<string, string[]>
  const other = () => (s.drafts().other ?? {}) as Record<string, string>
  return VStack({ spacing: 8 }, [
    ...questions.map((q) =>
      VStack({ spacing: 3 }, [
        caption(q.header ? `${q.header}: ${q.question}` : q.question),
        ...q.options.map((o) =>
          option(o.label, () => (selected()[q.id] ?? []).includes(o.id), () => s.setDraft("selected", { ...selected(), [q.id]: toggleOption(q, selected()[q.id] ?? [], o.id) })).help(o.description ?? o.label)
        ),
        q.allow_other ? TextField(() => other()[q.id] ?? "", { placeholder: t("answer.other"), onEdit: (text) => s.setDraft("other", { ...other(), [q.id]: text }) }) : null
      ])
    ),
    HStack([Button(t("answer.send"), () => (choiceComplete(questions, selected(), other()) ? reply(s, choiceAnswer(questions, selected(), other()))() : undefined)).disabled(() => !choiceComplete(questions, selected(), other())), Spacer()])
  ])
}

function fieldControl(s: DetailState, f: Field): CmuxView {
  const value = () => s.drafts()[f.key]
  const label = f.required ? `${f.title} *` : f.title
  if (f.type === "boolean") return option(label, () => value() === true, () => s.setDraft(f.key, value() !== true))
  if (f.type === "enum") {
    const picked = () => (Array.isArray(value()) ? (value() as string[]) : [])
    const toggle = (o: string) => s.setDraft(f.key, f.multi ? (picked().includes(o) ? picked().filter((x) => x !== o) : [...picked(), o]) : picked()[0] === o ? [] : [o])
    return VStack({ spacing: 3 }, [caption(label), HStack({ spacing: 4 }, [...f.options.map((o) => option(o, () => picked().includes(o), () => toggle(o))), Spacer()])])
  }
  return TextField(() => (typeof value() === "string" ? (value() as string) : ""), { placeholder: label, onEdit: (text) => s.setDraft(f.key, text) })
}

function fieldsControls(s: DetailState, fields: Field[]): CmuxView {
  const ready = () => fieldsAnswer(fields, s.drafts()).missing.length === 0
  return VStack({ spacing: 6 }, [
    ...fields.map((f) => fieldControl(s, f)),
    HStack([Button(t("answer.send"), () => (ready() ? reply(s, fieldsAnswer(fields, s.drafts()).value)() : undefined)).disabled(() => !ready()), Spacer()])
  ])
}

/** The controls a request's form asks for. Taps answer synchronously, with the tap's gesture (origin user). */
function formControls(s: DetailState, form: Form): CmuxView | null {
  switch (form.kind) {
    case "question":
      return VStack({ spacing: 4 }, [
        caption(form.question),
        ...form.suggestions.map((text) => Button(text, reply(s, { text }))),
        TextField(() => String(s.drafts().text ?? ""), {
          placeholder: t("answer.placeholder"),
          onEdit: (text) => s.setDraft("text", text),
          onSubmit: (text) => (text.trim() ? act(s, (i) => answer(i, { text: text.trim() }))() : undefined)
        })
      ])
    case "choice":
      return choiceControls(s, form.questions, form.oneTap)
    case "approve":
      return VStack({ spacing: 6 }, [
        caption(form.summary),
        form.command ? Text(form.command).font("caption").monospaced().lineLimit(4).padding(6).frame({ maxWidth: "infinity" }).background("hover").cornerRadius(6) : null,
        HStack({ spacing: 8 }, [
          Button(t("answer.allow"), reply(s, approveAnswer("allow"))),
          form.scopes.includes("session") ? Button(t("answer.allowSession"), reply(s, approveAnswer("allow", "session"))) : null,
          form.scopes.includes("always") ? Button(t("answer.allowAlways"), reply(s, approveAnswer("allow", "always"))) : null,
          Button(t("answer.deny"), reply(s, approveAnswer("deny"))).destructive(),
          Spacer()
        ])
      ])
    case "confirm": {
      const yes = Button(form.confirmLabel ?? t("answer.confirm"), reply(s, { confirmed: true }))
      return VStack({ spacing: 6 }, [caption(form.statement), HStack({ spacing: 8 }, [form.destructive ? yes.destructive() : yes, Button(form.cancelLabel ?? t("answer.reject"), reply(s, { confirmed: false })), Spacer()])])
    }
    case "browser":
      // Sign-in and passkey: feed.openItem runs the handover; the Mac's browser answers, never a typed value.
      return VStack({ spacing: 6 }, [
        caption([form.origin, form.reason].filter(Boolean).join(" · ")),
        HStack([Button(t("answer.continueInBrowser"), act(s, openItem)), Spacer()]),
        Text(t("answer.browserHelp")).font("caption").color("tertiary").lineLimit(3)
      ])
    case "review":
      return VStack({ spacing: 6 }, [
        caption(form.ref),
        TextField(() => String(s.drafts().comment ?? ""), { placeholder: t("answer.comment"), onEdit: (text) => s.setDraft("comment", text) }),
        HStack({ spacing: 8 }, [
          Button(t("answer.approveReview"), () => reply(s, withComment({ verdict: "approve" }, s))()),
          Button(t("answer.requestChanges"), () => reply(s, withComment({ verdict: "request_changes" }, s))()),
          Spacer()
        ])
      ])
    case "handoff":
      return VStack({ spacing: 6 }, [caption(form.reason), HStack({ spacing: 8 }, [Button(t("answer.takeOver"), reply(s, { status: "taken_over" })), Button(t("answer.resume"), reply(s, { status: "resumed" })), Spacer()])])
    case "fields":
      return fieldsControls(s, form.fields)
    case "unsupported":
      return caption(t("answer.unsupported"))
    case "none":
      return null
  }
}

function withComment(value: { verdict: string }, s: DetailState) {
  const comment = String(s.drafts().comment ?? "").trim()
  return comment ? { ...value, comment } : value
}

/** The answer form of the selected request, rebuilt only when the form changes. */
export function AnswerForm(s: DetailState): CmuxView {
  return Group([
    () => {
      s.form()
      const i = s.peek()
      if (!i) return null
      const buttons = answerButtons(i)
      const controls = formControls(s, formOf(i))
      if (!buttons.length) return controls
      return VStack({ spacing: 6 }, [
        controls,
        HStack({ spacing: 8 }, [
          ...buttons.map((a) => {
            const b = Button(a.label, reply(s, a.answer))
            return a.style === "destructive" ? b.destructive() : b
          }),
          Spacer()
        ])
      ])
    }
  ])
}

/**
 * Open, the poster's open-only buttons, and triage. An open request offers
 * Decline instead of Done and Snooze (the owner refuses both for it); a done
 * item offers Move Back to Inbox.
 */
export function Actions(s: DetailState, withSkip: boolean): CmuxView {
  return Group([
    () => {
      s.form()
      const i = s.peek()
      if (!i) return null
      const browser = i.kind === "sign-in" || i.kind === "passkey"
      const opens = openButtons(i).map((a) => Button(a.label, act(s, openItem)))
      const triage = isOpenRequest(i)
        ? [Button(t("action.decline"), act(s, decline)).destructive()]
        : i.archived_at !== null
          ? [Button(t("action.unarchive"), act(s, (x) => unarchive([x])))]
          : [Button(t("action.doneShort"), act(s, (x) => markDone([x]))), snoozeMenu(() => (s.peek() ? [s.peek()!] : []))]
      return HStack({ spacing: 8 }, [browser && isOpenRequest(i) ? null : Button(t("action.open"), act(s, openItem)), ...opens, ...triage, Spacer(), withSkip ? Button(t("action.skip"), () => step(1, s.id())) : null])
    }
  ])
}

/** Kind, poster, place, age, title and body of the selected item. */
export function Summary(s: DetailState, titleFont: string): CmuxView {
  const get = () => s.item()
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      Icon(() => (get() ? itemSymbol(get()!) : "tray")).color(() => (get() ? itemTint(get()!) : "secondary")).font("caption"),
      Text(() => {
        const i = get()
        return i ? [kindLabel(i), i.poster.label, s.workspace(i.context.workspace)].filter(Boolean).join(" · ") : ""
      })
        .font("caption")
        .color("secondary")
        .lineLimit(1),
      Spacer(),
      Text(() => (get() ? ago(get()!.updated_at, Date.now()) : "")).font("caption").color("tertiary")
    ]),
    Text(() => get()?.title ?? "").font(titleFont).lineLimit(4),
    Group([
      () =>
        s.form() && s.peek()?.body
          ? Text(() => get()?.body ?? "")
              .font("callout")
              .color("secondary")
              .lineLimit(10)
              .padding(8)
              .frame({ maxWidth: "infinity" })
              .background("hover")
              .cornerRadius(6)
          : null
    ])
  ])
}

/** The full detail area, or a hint when nothing is selected. */
export function Detail(s: DetailState): CmuxView {
  return Group([() => (s.has() ? VStack({ spacing: 12 }, [Summary(s, "headline"), AnswerForm(s), Actions(s, false)]) : Text(t("detail.none")).font("callout").color("tertiary").padding(12))])
}

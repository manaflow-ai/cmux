/// <reference path="../../../cmux-app-host/generated/cmux-app.d.ts" />
// cmux-extension-sdk: the public API for code cmux runs in its extension sandbox.
//
// An extension is a folder with a manifest (cmux-app.json) and a script. The manifest says which
// places it fills (`implements`: a sidebar section, a pane) and which export draws each one; the
// script exports those functions. `cmux ext dev` bundles the script with this package, loads it
// into the running cmux and reloads it on every save.
//
// Everything here is a typed name for what the cmux runtime already defines in the sandbox
// (cmux-app.d.ts), plus a few helpers built only on it, so a bundle that imports this package
// adds a few hundred bytes and no runtime of its own.

// The tables are the runtime's own (cmux-app-host): the event streams, and the op scopes the
// generator checks them against. Nothing here is a copy that could drift from them.
import eventTable from "../../../cmux-app-host/schema/v2/events.json" with { type: "json" }
import scopeTable from "../../../cmux-app-host/generated/scopes.json" with { type: "json" }

/** This package's version. */
export const SDK_VERSION = "1.0.0"
/** The app API this package types (`cmux app API` in cmux-app.d.ts). */
export const API_VERSION: string = scopeTable.apiVersion

// ---------------------------------------------------------------------------------------------
// The runtime's globals, as imports.

/** Every op cmux gives an extension, checked by the host against the scopes the person granted. */
// `cmux` is a declared const (not a globalThis property to the type checker), and `Text` and `Image`
// share their names with DOM types when the author's tsconfig loads the DOM lib: name all three.
type Globals = Omit<typeof globalThis, "Text" | "Image"> & {
  cmux: CmuxGlobal
  Text(text: Bindable<string | number | null | undefined> | CmuxDateText): CmuxView
  Image(source: Bindable<string> | { systemName: Bindable<string> }): CmuxView
}
const g = globalThis as unknown as Globals

/** The runtime this extension runs in (it sets the global before the extension loads); an older cmux answers `operation.unsupported` for newer ops. */
export const RUNTIME_VERSION: string = String((globalThis as { __cmuxAppRuntimeVersion?: unknown }).__cmuxAppRuntimeVersion ?? "")

export const cmux: CmuxGlobal = g.cmux

/** Reactive state: a view that reads a signal redraws when it changes. */
export const { signal, computed, effect, onCleanup, untrack } = g

/** The scene DSL: cmux draws these natively in the sidebar and in panes. Colors are theme tones (`cmux.theme`), never raw values. */
export const {
  VStack, HStack, ZStack, LazyVStack, Group, ForEach, Reorderable,
  Text, Icon, Image, Button, Menu, Spacer, Divider, Row, Badge, EmptyState, Panel,
  Toggle, Slider, TextField, ProgressView, Circle, Capsule, Rectangle, RoundedRectangle, Line
} = g

/** cmux's own New Tab composer at this place in a New Tab page (`newTab(...)`), with its project and
 * agent chips; `prompt` for the Console's `>`, `cwd` to move the next chat's folder. Draws nothing
 * elsewhere, and on a cmux older than the node. */
export const Composer: Globals["Composer"] = g.Composer ?? (() => g.Group([]))

/** Gradient fills for `.background(...)` and a shape's `.fill(...)`: 2 to 8 stops (tones or
 * `#RRGGBB[AA]`); the runtime's builders refuse a bad stop or angle. On a cmux older than them the
 * value is built here and an older renderer draws no fill. */
export const linearGradient: (colors: readonly string[], angle?: number) => CmuxGradient =
  g.linearGradient ?? ((colors, angle) => ({ linear: angle === undefined ? { colors: [...colors] } : { colors: [...colors], angle } }))
export const radialGradient: (colors: readonly string[]) => CmuxGradient =
  g.radialGradient ?? ((colors) => ({ radial: { colors: [...colors] } }))

export type View = CmuxView
export type Signal<T> = CmuxSignal<T>
export type Gradient = CmuxGradient
export type Fill = CmuxFill

// ---------------------------------------------------------------------------------------------
// Places. Export the result under the name the manifest gives the place's `export`.

/** Context a section or pane render gets: Session Info sections receive `{session_id, cwd, branch?, harness?}`. */
export type MountContext = CmuxAppContext

/**
 * A sidebar section (`cmux.section/1`). The person places it; it draws once per mount and redraws
 * only the nodes whose signals change.
 *
 *     // cmux-app.json: "implements": { "cmux.section/1": { "export": "renderSection", "title": "My section" } }
 *     export const renderSection = section(() => VStack([Text("Hello")]))
 */
export function section(render: (context: MountContext) => View): (context: MountContext) => View {
  return render
}

/** A pane (`cmux.pane/1`): a tab kind the person opens from the palette or an op. Same scene DSL as a section. */
export function pane(render: (context: MountContext) => View): (context: MountContext) => View {
  return render
}

/** Context a New Tab page render gets: the folder the new tab starts in, when it has one. */
export type NewTabContext = { surface: "newTab"; cwd?: string }

/**
 * A whole New Tab page (`cmux.newtab/1`): the scene is the page's body, in place of cmux's own page.
 * It shows only once the person picks the extension (`cmux settings set tabs.newTabApp <id>`); when
 * it is hidden, disabled or its render fails, cmux draws its own page. Open the tab the person asks
 * for with `cmux.actions.run` from a click (scope `actions:run`).
 *
 *     // cmux-app.json: "implements": { "cmux.newtab/1": { "export": "renderNewTab", "title": "Launcher" } }
 *     export const renderNewTab = newTab(() => VStack([Text("Good morning")]))
 */
export function newTab(render: (context: NewTabContext) => View): (context: NewTabContext) => View {
  return render
}

/** The tool call a chat widget draws: its name, and its input and result as the agent sent them (each cut to 16 KiB). */
export type ChatWidgetTool = { name: string; title?: string; status?: string; input?: unknown; output?: string }

/**
 * Context a chat widget render gets. `widget.key` is stable for the call or the part: keep state
 * that must outlive the extension in `cmux.storage` under it. `tool` is set under a tool call,
 * `props` for a widget part an agent sent.
 */
export type ChatWidgetContext = {
  surface: "chatWidget"
  widget: { key: string }
  tool?: ChatWidgetTool
  props?: Record<string, unknown>
}

/**
 * A chat widget (`cmux.chat.widget/1`): a card in the agent chat, under every tool call whose name
 * matches the manifest's `options.tools` (`*` matches any run of characters), and for widget parts
 * an agent sends naming this extension. cmux ships no widgets of its own; when the extension is
 * missing, hidden or its render fails, the chat shows the call as it always did. The same render
 * can be exported again with `section(...)` to show in the sidebar.
 *
 *     // cmux-app.json: "implements": { "cmux.chat.widget/1": { "export": "renderCard", "title": "PR",
 *     //   "options": { "tools": ["mcp__github__*pull_request*"] } } }
 *     export const renderCard = chatWidget((ctx) => Text(ctx.tool?.name ?? "widget"))
 */
export function chatWidget(render: (context: ChatWidgetContext) => View): (context: ChatWidgetContext) => View {
  return render
}

/** A command (a catalog op the extension declares in catalog.json): runs from the palette, the CLI or another extension. */
export function command<A, R>(run: (args: A, ctx: { app: string; gesture?: string; cmux: CmuxGlobal }) => R | Promise<R>) {
  return run
}

// ---------------------------------------------------------------------------------------------
// Composer places. These are data in the manifest, not exports: cmux's daemon reads them and
// answers the agent chat composer, so a save of cmux-app.json updates the composer live.

/**
 * A slash command in the agent chat composer (`cmux.composer.command/1`). Picking `/name` in the
 * `/` menu writes `insert` over the typed `/word`.
 *
 *     // cmux-app.json: "implements": { "cmux.composer.command/1": { "options": { "commands": [
 *     //   { "name": "standup", "description": "Ask for today's standup", "insert": "Write my standup notes." } ] } } }
 */
export interface ComposerCommand {
  /** What the person types after `/`: lowercase letters, digits, `-` and `_`, at most 32. */
  name: string
  /** The menu row's sentence. */
  description?: string
  /** What follows the command, shown after its name (`<ticket>`). */
  hint?: string
  /** The text written over the typed `/word`. */
  insert: string
}

/** Data-only `options` of `cmux.composer.model.picker/1`. */
export interface ComposerModelPickerOptions {
  modelMenu: 'search'
  reasoningMenu: 'column' | 'separate'
}

/** The `options` of `cmux.composer.command/1`. */
export interface ComposerCommandOptions {
  commands: ComposerCommand[]
}

/** An item the person names with `@` in the composer (`cmux.composer.mention/1`); the daemon ranks them for a query. */
export interface ComposerMention {
  id: string
  /** What the row shows and what a query matches. */
  label: string
  detail?: string
  /** What the mention writes; the label when absent. */
  insert?: string
}

/** The `options` of `cmux.composer.mention/1`. */
export interface ComposerMentionOptions {
  /** The word that narrows `@` to this provider (`@ticket:`). */
  prefix: string
  items: ComposerMention[]
}

/**
 * A context chip in the agent chat composer (`cmux.composer.chip/1`): a short label the person
 * clicks to add `insert` to the draft. The daemon lists chips in `apps.composer.list`.
 *
 *     // cmux-app.json: "implements": { "cmux.composer.chip/1": { "options": { "chips": [
 *     //   { "id": "branch", "label": "Branch", "insert": "Work on the current git branch." } ] } } }
 */
export interface ComposerChip {
  /** Unique in the extension: lowercase letters, digits, `.`, `_` and `-`, at most 64. */
  id: string
  /** What the chip shows, at most 32 characters. */
  label: string
  /** The chip's tooltip. */
  detail?: string
  /** The text a click adds to the draft. */
  insert: string
}

/** The `options` of `cmux.composer.chip/1`: up to 12 chips. */
export interface ComposerChipOptions {
  chips: ComposerChip[]
}

// ---------------------------------------------------------------------------------------------
// Events. An event is an invalidation with no payload; the live lists below re-read on it.

/** The streams an extension can subscribe to, with the read op (and so the scope) each needs. */
export type EventStream = keyof typeof eventTable.events
export const EVENT_STREAMS = Object.keys(eventTable.events) as EventStream[]

/** The scope the manifest must ask for to hear `stream` (`workspace:read` for `workspace.changed`). */
export function scopeFor(stream: EventStream): string {
  const event = eventTable.events[stream] as { reads: string; scope?: string }
  // A reads op with a placeholder scope (integration.request): the stream names its own (github.changed).
  if (event.scope) return event.scope
  return scopeTable.ops[event.reads as keyof typeof scopeTable.ops].scope
}

/**
 * Calls `fn` each time `stream` fires; returns the unsubscribe. Inside a render or an effect it is
 * also unsubscribed when that render or effect is disposed. An unknown stream throws, so a typo
 * fails at load instead of never firing.
 */
export function on(stream: EventStream, fn: () => void): () => void {
  if (!Object.hasOwn(eventTable.events, stream)) {
    throw new Error(`cmux-extension-sdk: unknown event stream ${JSON.stringify(stream)}; known: ${EVENT_STREAMS.join(", ")}`)
  }
  const off = cmux.events.on(stream, () => fn())
  onCleanup(off)
  return off
}

// ---------------------------------------------------------------------------------------------
// Live lists: read once, re-read when cmux pushes the matching event, shared by every reader in
// the extension, nothing polled. Each needs the scope its event needs.

/** A live value: call it for the latest value (undefined until the first read), with its status. */
export interface Live<T> {
  (): T | undefined
  loading(): boolean
  error(): CmuxError | undefined
  refresh(): void
}

export type Workspace = Cmux.WorkspaceSnapshot
export type Agent = Cmux.AgentSnapshot
/** Whether the extension may read the person's calendar (`cmux.system_calendar.events`, `cmux.system_calendar.request_access`). */
export type CalendarAccess = CmuxCalendarAccess
/** One event of the person's calendar; `start` and `end` are epoch ms. */
export type CalendarEvent = CmuxCalendarEvent
/** `cmux.system_calendar.events`' answer. */
export type CalendarEvents = CmuxCalendarEvents
/** An agent chat as the sidebar shows it. */
export interface Chat {
  id: string
  title: string
  state: "working" | "input" | "idle" | "failed" | "lost" | (string & {})
  unread: boolean
  harness: string | null
  project: string | null
  cwd: string | null
  workspace: string | null
  machine: string | null
  updated_ms: number
  created_ms?: number | null
  pinned?: boolean
  /** The chat whose agent started this one, when one did. */
  parent?: string | null
  /** Its last reply, one short line (a New Tab card's message); null before the first, absent on an older cmux. */
  preview?: string | null
  pull_requests?: string[]
}

/** What `recentChats` reads: at most `limit` chats (1 to 1000), newest first, only those in `state` when given. */
export interface RecentChatsQuery {
  limit: number
  state?: "working" | "input" | "idle" | "failed" | "lost"
  /** The page after this row (a previous page's last chat): All chats, a page at a time. */
  after?: Pick<Chat, "id" | "updated_ms" | "machine"> & { created_ms?: number | null }
}

function fromWatch<T>(w: CmuxWatch<T>): Live<T> {
  const live = (() => w.value()) as Live<T>
  live.loading = () => w.status() === "loading"
  live.error = () => w.error()
  live.refresh = () => void w.refresh()
  return live
}

/** The workspaces of this session, in sidebar order (scope `workspace:read`, pushed by `workspace.changed`). */
export function workspaces(): Live<Workspace[]> {
  return fromWatch(cmux.watch("workspace.list"))
}

/** The agents of this session and their state (scope `agent:read`, pushed by `agent.changed`). */
export function agents(): Live<Agent[]> {
  return fromWatch(cmux.watch("agent.list"))
}

/** The agent chats the sidebar lists (scope `agent_chat:read`, pushed by `agent_chat.changed`). */
export function chats(): Live<Chat[]> {
  const l = cmux.live<Chat[]>("agent_chat.list", {}, {
    events: ["agent_chat.changed"],
    select: (v) => ((v as { chats?: Chat[] } | null)?.chats ?? [])
  })
  const live = (() => l()) as Live<Chat[]>
  live.loading = () => l.loading()
  live.error = () => l.error() ?? undefined
  live.refresh = () => l.refresh()
  return live
}

/** The `agent_chat.list` fields a recent-chats query names. */
export function recentChatsFields(query: RecentChatsQuery): Record<string, unknown> {
  const fields: Record<string, unknown> = { limit: query.limit }
  if (query.state) fields.state = query.state
  const after = query.after
  if (after) {
    fields.before_ms = after.updated_ms ?? after.created_ms ?? 0
    fields.before_id = after.id
    if (after.machine) fields.before_machine = after.machine
  }
  return fields
}

/**
 * The newest agent chats, at most `query.limit`: a New Tab page's recent chats, a "waiting on you"
 * list (`state: "input"`), or one page of All chats (`after` the previous page's last chat). cmux
 * reads them from its ordered chat index, so the read costs the chats it returns, never a sort of
 * every chat (scope `agent_chat:read`, pushed by `agent_chat.changed`).
 *
 *     const recent = recentChats({ limit: 3 })
 *     ForEach({ items: () => recent() ?? [], key: (c) => c.id }, (c) => Row({ title: () => c().title }))
 */
export function recentChats(query: RecentChatsQuery): Live<Chat[]> {
  const l = cmux.live<Chat[]>("agent_chat.list", recentChatsFields(query), {
    events: ["agent_chat.changed"],
    select: (v) => ((v as { chats?: Chat[] } | null)?.chats ?? [])
  })
  const live = (() => l()) as Live<Chat[]>
  live.loading = () => l.loading()
  live.error = () => l.error() ?? undefined
  live.refresh = () => l.refresh()
  return live
}

/**
 * Calls `fn` with the new value each time a live list changes (not for the first read when
 * `initial` is false). Returns the stop function; inside a render or effect it stops with it.
 */
export function onChange<T>(live: Live<T>, fn: (value: T) => void, options: { initial?: boolean } = {}): () => void {
  let skip = options.initial === false
  return effect(() => {
    const value = live()
    if (value === undefined) return
    if (skip) {
      skip = false
      return
    }
    untrack(() => fn(value))
  })
}

// ---------------------------------------------------------------------------------------------
// Widgets (`cmux.widget/1`): the place and its glanceable layout helpers (widget.ts).

export * from "./widget.ts"

// ---------------------------------------------------------------------------------------------
// Design systems (`cmux.design/1`): cmux's as data, a person's on top of it, and its viewer (design.ts).

export * from "./design.ts"

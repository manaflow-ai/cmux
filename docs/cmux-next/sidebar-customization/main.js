// My cmux sidebar customization. Edit and save: cmux reloads it at once.
// The view language is the classic cmux JS sidebar one (VStack, HStack, Text, Icon, Spacer,
// signal, computed, ForEach). A script error shows under the built-in card, which stays.

// ---- Hover card --------------------------------------------------------------------------
// The fields the card shows, in this order. Remove a name to hide that field.
const FIELDS = ["needsInput", "notification", "unread", "task", "agent", "command", "presence", "lastReply", "folder", "branch", "pullRequest", "machine", "status"]

const ICONS = {
  needsInput: "questionmark.bubble", notification: "bell", unread: "bell", agent: "sparkles", task: "text.alignleft", lastReply: "text.bubble",
  presence: "pencil", command: "terminal", folder: "folder", branch: "arrow.triangle.branch",
  pullRequest: "arrow.triangle.pull", machine: "desktopcomputer", status: "circle.fill", more: "ellipsis",
}

function elapsed(sinceMs, now) {
  const s = Math.max(1, Math.floor((now - sinceMs) / 1000))
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ${s % 60}s`
  return `${Math.floor(m / 60)}h ${m % 60}m`
}

// ctx.target is the hovered row ({kind: "workspace", id}); ctx.card is what the built-in card
// shows: {title, status, statusSinceMs, age, facts: [{kind, text, sinceMs}]}.
function renderCard(ctx) {
  const card = ctx.card
  // A clock for the running times; it ticks only while the card shows.
  const [now, setNow] = signal(Date.now())
  const tick = cmux.timer.every(1000, () => setNow(Date.now()))
  onCleanup(() => cmux.timer.clear(tick))
  const facts = FIELDS.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  const timed = (text, since) => () => (since ? `${text} · ${elapsed(since, now())}` : text)
  return VStack({ spacing: 6 }, [
    Text(card.title).bold().lineLimit(2),
    card.status ? Text(timed(card.status, card.statusSinceMs)).secondary() : null,
    ...facts.map((fact) =>
      HStack({ spacing: 6 }, [
        Icon(ICONS[fact.kind] ?? "circle"),
        Text(timed(fact.text, fact.sinceMs)).lineLimit(fact.kind === "task" ? 3 : 1),
      ]),
    ),
  ])
}

// ---- Row decorations -----------------------------------------------------------------------
// The first rule whose `match` fits a workspace's name decorates its row. icon: an SF Symbol
// name or one emoji; weight: regular, medium, semibold or bold; indicator: default, none, arc,
// dot, braille or native; badge: short text the row shows as its status line.
const RULES = [
  { match: /^api/i, icon: "🚀", weight: "semibold" },
  { match: /prod/i, icon: "exclamationmark.triangle", indicator: "dot" },
]

function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  const rule = (name) => RULES.find((r) => r.match.test(name ?? "")) ?? {}
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({
        title: () => w().name,
        icon: () => rule(w().name).icon ?? null,
        weight: () => rule(w().name).weight ?? null,
        indicator: () => rule(w().name).indicator ?? null,
        badge: () => rule(w().name).badge ?? null,
      }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }

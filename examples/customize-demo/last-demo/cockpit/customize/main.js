// Cockpit, redone: the New Tab page is mission control and the sidebar gets a Needs You section on
// top. The page reads like a dashboard someone designed: a greeting that says what waits on you, a
// strip of live counters whose digits roll when they change, four launch tiles, and three cards
// with a header, a count and a divider each. Both places read the same chat list: one read per
// change (agent_chat.changed), no polling. Workspaces and PRs come from cmux.watch, which the
// daemon pushes. Only the kit: tones, not colors; fonts by name, not sizes.

const [chats, setChats] = signal([])
const [now, setNow] = signal(Date.now())

let reading = false
let again = false
async function load() {
  if (reading) return void (again = true)
  reading = true
  try {
    setChats((await cmux.call("agent_chat.list", {})).chats)
  } catch (e) {
    setChats([])
  } finally {
    reading = false
    if (again) {
      again = false
      load()
    }
  }
}

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Cockpit`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

const failed = (c) => c.state === "failed" || c.state === "lost"
const waiting = (c) => c.state === "input" || failed(c) || c.unread
const why = (c) => (c.state === "input" ? "asks you" : failed(c) ? "stopped with an error" : "done, unread")
const toneOf = (c) => (c.state === "input" ? cmux.theme.warning : failed(c) ? cmux.theme.danger : cmux.theme.success)
const symbolOf = (c) => (c.state === "input" ? "questionmark.bubble.fill" : failed(c) ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
const needsYou = computed(() => chats().filter(waiting))
const working = computed(() => chats().filter((c) => c.state === "working"))

function show(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).catch(refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id })
}

function chatRow(c) {
  return Row({
    title: () => c().title,
    subtitle: () => `${c().project || "No folder"} · ${why(c())}`,
    symbol: () => symbolOf(c()),
    tint: () => toneOf(c())
  })
    .transition("slide")
    .onTap(() => show(c()))
}

let following = false
function follow() {
  load()
  if (following) return
  following = true
  cmux.events.on("agent_chat.changed", load)
}

// ---- The header: a greeting, what waits on you, the time ---------------------------------------

const two = (n) => String(n).padStart(2, "0")
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
const clock = computed(() => {
  const d = new Date(now())
  return `${two(d.getHours())}:${two(d.getMinutes())}`
})
const date = computed(() => {
  const d = new Date(now())
  return `${DAYS[d.getDay()]}, ${MONTHS[d.getMonth()]} ${d.getDate()}`
})
const greeting = computed(() => {
  const h = new Date(now()).getHours()
  return h < 5 ? "Burning the midnight oil" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
})
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`
const summary = computed(() => {
  const n = needsYou().length
  const w = working().length
  if (!n && !w) return "All clear. No chat is waiting on you and nothing is running."
  if (!n) return `Nothing waits on you. ${plural(w, "chat is", "chats are")} at work.`
  return `${plural(n, "chat needs", "chats need")} you${w ? `, ${plural(w, "more is", "more are")} at work` : ""}.`
})

function header() {
  return HStack({ spacing: 16, alignment: "bottom" }, [
    VStack({ spacing: 4, alignment: "leading" }, [
      Text(greeting).font("largeTitle").weight("bold"),
      Text(summary).font("title3").color(cmux.theme.text.secondary).contentTransition("opacity")
    ]),
    Spacer(),
    VStack({ spacing: 2, alignment: "trailing" }, [
      Text(clock).font("largeTitle").weight("light").monospaced().contentTransition("numericText"),
      Text(date).font("callout").color(cmux.theme.text.secondary)
    ])
  ])
}

// ---- The counters: icon in a tinted disc, a big rolling number, a label ------------------------

function stat(symbol, label, value, tone) {
  return Panel({ style: "glass" }, [
    HStack({ spacing: 12 }, [
      ZStack([
        Circle().fill(tone).opacity(0.18).frame({ width: 40, height: 40 }),
        Icon(symbol).font("title3").color(tone).symbolRendering("hierarchical")
      ]).frame({ width: 40, height: 40 }),
      VStack({ spacing: 0, alignment: "leading" }, [
        Text(value).font("title").weight("semibold").monospaced().contentTransition("numericText").color(tone).animation("smooth"),
        Text(label).font("caption").weight("medium").color(cmux.theme.text.secondary)
      ]),
      Spacer()
    ])
  ]).frame({ maxWidth: "infinity" })
}

// ---- Launch tiles: one tap to a new chat, terminal, browser, or the next chat that waits ------

function tile(symbol, label, hint, action) {
  return Button(
    VStack({ spacing: 6, alignment: "center" }, [
      Icon(symbol).font("title2").color(cmux.theme.accent).symbolRendering("hierarchical"),
      Text(label).font("callout").weight("semibold"),
      Text(hint).font("caption2").color(cmux.theme.text.tertiary)
    ]).paddingVertical(10).frame({ maxWidth: "infinity" }),
    action
  ).frame({ maxWidth: "infinity" })
}

function nextWaiting() {
  const first = needsYou()[0]
  if (first) show(first)
  else cmux.toast({ title: "Nothing waits on you", tone: "success" })
}

// ---- Cards: a header with an icon, a title and a count, a divider, then the rows ---------------

function card(symbol, title, tone, count, children) {
  return Panel({ style: "glass", spacing: 8 }, [
    HStack({ spacing: 8 }, [
      Icon(symbol).color(tone).symbolRendering("hierarchical"),
      Text(title).font("headline"),
      Spacer(),
      Badge(count, tone)
    ]),
    Divider(),
    ...children
  ]).frame({ maxWidth: "infinity" })
}

function renderCockpit() {
  follow()
  cmux.timer.every(15000, () => setNow(Date.now()))
  const workspaces = cmux.watch("workspace.list")
  const prs = cmux.watch("github.pulls", { roles: ["review-requested", "author"], limit: 6 })
  const prList = () => prs.value() ?? []
  const reviews = computed(() => prList().filter((p) => p.roles.includes("review-requested")).length)
  return VStack({ spacing: 18 }, [
    header(),
    HStack({ spacing: 12 }, [
      stat("bell.badge.fill", "need you", () => String(needsYou().length), () => (needsYou().length ? cmux.theme.warning : cmux.theme.text.secondary)),
      stat("sparkles", "at work", () => String(working().length), cmux.theme.accent),
      stat("eye.fill", "reviews for you", () => String(reviews()), () => (reviews() ? cmux.theme.warning : cmux.theme.text.secondary)),
      stat("rectangle.stack.fill", "workspaces", () => String((workspaces.value() ?? []).length), cmux.theme.success)
    ]),
    HStack({ spacing: 10 }, [
      tile("bubble.left.and.text.bubble.right.fill", "New chat", "Ask an agent", () => run("palette.newAgentChat")),
      tile("terminal.fill", "Terminal", "In this folder", () => run("newSurface")),
      tile("globe", "Browser", "A new page", () => run("openBrowser")),
      tile("arrow.turn.down.right", "Next waiting", "Jump to it", nextWaiting)
    ]),
    HStack({ spacing: 12, alignment: "top" }, [
      card("bell.badge.fill", "Needs you", () => (needsYou().length ? cmux.theme.warning : cmux.theme.success), () => String(needsYou().length), [
        ForEach({ items: needsYou, key: (c) => c.id }, chatRow),
        () => (needsYou().length ? null : EmptyState({ title: "Nothing waits on you", message: "Chats that ask you something or finish show up here.", symbol: "checkmark.seal.fill" }))
      ]),
      card("arrow.triangle.pull", "Your pull requests", cmux.theme.accent, () => String(prList().length), [
        ForEach({ items: prList, key: (p) => p.id }, (p) =>
          Row({
            title: () => p().title,
            subtitle: () => `${p().repo} · #${p().number}${p().roles.includes("review-requested") ? " · waiting on your review" : ""}`,
            symbol: () => (p().roles.includes("review-requested") ? "eye.circle.fill" : "arrow.triangle.pull"),
            tint: () => (p().roles.includes("review-requested") ? cmux.theme.warning : cmux.theme.success)
          })
            .help(() => p().url)
            .onTap(() => run("openBrowser", { url: p().url }))
        ),
        () =>
          prs.status() === "error"
            ? EmptyState({ title: "GitHub is not connected", message: "Connect it in Settings > Integrations to see your pull requests here.", symbol: "link.badge.plus" })
            : prs.value() && !prList().length
              ? EmptyState({ title: "No open pull requests", symbol: "checkmark.circle" })
              : null
      ])
    ]),
    card("rectangle.stack.fill", "Workspaces", cmux.theme.text.secondary, () => String((workspaces.value() ?? []).length), [
      ForEach({ items: () => workspaces.value() ?? [], key: (w) => w.id }, (w) =>
        Row({
          title: () => w().name,
          symbol: () => (w().focused ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle"),
          selected: () => w().focused,
          accessory: () => (w().focused ? "here" : null)
        }).onTap(() => cmux.workspace.focus({ workspace: w().id }).catch(refused("Change workspaces")))
      )
    ]),
    Spacer()
  ]).padding()
}

function renderNeedsYou() {
  follow()
  return VStack({ spacing: 2 }, [
    ForEach({ items: needsYou, key: (c) => c.id }, chatRow),
    () =>
      needsYou().length
        ? null
        : HStack({ spacing: 6 }, [Icon("checkmark.seal.fill").color(cmux.theme.success), Text("All clear").font("callout").color(cmux.theme.text.secondary), Spacer()]).paddingHorizontal(10).paddingVertical(4)
  ])
}

globalThis.__cmuxAppExports = { renderCockpit, renderNeedsYou }

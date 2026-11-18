// Changes: a live list of pull requests in the sidebar, like a session rail's Changes list. It
// imports nothing but the public SDK, and nothing in cmux turns it on: you add it.
// - cmux.watch("github.changes") does the reading, through your GitHub sign-in (the token stays in
//   cmux) or, without one, GitHub's public API. Each read is a conditional request, so a list where
//   nothing moved costs GitHub nothing; nothing here polls.
// - Settings > Apps > Changes picks which pull requests: this workspace's branch, yours, the ones
//   mentioning you, the ones asking for your review, or a saved search.
// - A click opens the pull request in a cmux browser tab. The ⋯ menu opens it on GitHub, copies its
//   link, or checks it out in a new workspace.
// - Three looks (the `look` variant): rail (two lines, the reference), compact (one line) and panel.

import {
  Button, cmux, computed, Divider, effect, EmptyState, ForEach, HStack, Icon, Menu, Panel, Row, signal, Spacer, Text, VStack, workspaces,
  type View
} from "cmux-extension-sdk"

export type Change = CmuxSignalMap["github.changes"]["value"][number]
type Show = "branch" | "mine" | "mentions" | "review-requested" | "search"
type Look = "rail" | "compact" | "panel"

const FIRST = 5

/** 61331 -> "61,331" (the sandbox has no Intl). */
export function grouped(n: number): string {
  const s = String(Math.max(0, Math.round(n)))
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

/** What the checks say, as the row's third part: "2 failing", "3 running", "Checks passed", "Merged". */
export function checkLine(c: Change): { text: string; tone: string } {
  if (c.state === "merged") return { text: "Merged", tone: cmux.theme.accent }
  if (c.checks.state === "failing") return { text: `${c.checks.failing} failing`, tone: cmux.theme.danger }
  if (c.checks.state === "pending") return { text: `${c.checks.pending} running`, tone: cmux.theme.warning }
  if (c.checks.state === "passing") return { text: "Checks passed", tone: cmux.theme.success }
  return { text: "No checks", tone: cmux.theme.text.tertiary }
}

export function reviewLine(c: Change): { text: string; tone: string } | null {
  if (c.state !== "open") return null
  if (c.review === "approved") return { text: "Approved", tone: cmux.theme.success }
  if (c.review === "changes-requested") return { text: "Changes requested", tone: cmux.theme.danger }
  if (c.review === "review-required") return { text: "Review requested", tone: cmux.theme.text.secondary }
  return null
}

export function symbolOf(c: Change): { symbol: string; tone: string } {
  if (c.state === "merged") return { symbol: "arrow.triangle.merge", tone: cmux.theme.accent }
  if (c.draft) return { symbol: "circle.dashed", tone: cmux.theme.text.secondary }
  if (c.checks.state === "failing") return { symbol: "arrow.triangle.pull", tone: cmux.theme.danger }
  return { symbol: "arrow.triangle.pull", tone: cmux.theme.success }
}

/** "manaflow-ai/cmux" -> "cmux": the row names the repository the way the reference does. */
const shortRepo = (repo: string) => repo.split("/")[1] ?? repo

/** The shell line that checks a pull request out in a new worktree (only digits and a checked slug reach it). */
export function checkoutScript(c: Change, root: string | null): string | null {
  // Neither part may start with "-" (it would read as an option to gh or cd).
  if (!/^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._][A-Za-z0-9._-]*$/.test(c.repo) || !Number.isInteger(c.number) || c.number <= 0) return null
  const name = `${shortRepo(c.repo)}-pr-${c.number}`
  const q = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`
  const shell = 'exec "${SHELL:-/bin/zsh}" -l'
  if (root) {
    const dir = `${root.replace(/\/+$/, "")}-pr-${c.number}`
    return `cd ${q(root)} && git fetch ${q(`https://github.com/${c.repo}.git`)} pull/${c.number}/head:pr-${c.number} && git worktree add ${q(dir)} pr-${c.number} && cd ${q(dir)}; ${shell}`
  }
  return `mkdir -p "$HOME/cmux-prs" && cd "$HOME/cmux-prs" && gh repo clone ${c.repo} ${name} -- --filter=blob:none && cd ${name} && gh pr checkout ${c.number}; ${shell}`
}

// The selected workspace's repository and branch, for show: branch. Re-read whenever the selected
// workspace's entry changes (workspace.changed), not only when another one is selected; an answer
// for a selection that has since moved on is dropped. git.status with github: true is one git run more.
const [here, setHere] = signal<{ workspace: string; root: string; repo: string | null; branch: string | null } | null>(null)
let hereFor = ""
let asked = 0
function follow(spaces: () => Array<{ id: string; focused: boolean }> | undefined) {
  const focused = (spaces() ?? []).find((w) => w.focused)
  const key = focused ? JSON.stringify(focused) : ""
  if (!focused || key === hereFor) return
  hereFor = key
  const mine = ++asked
  const keepIf = (v: { workspace: string; root: string; repo: string | null; branch: string | null }) => {
    if (mine === asked) setHere(v)
  }
  cmux.git
    .status({ workspace: focused.id, github: true })
    .then((s) => keepIf({ workspace: focused.id, root: s.root, repo: s.github_repo ?? null, branch: s.branch ?? null }))
    .catch(() => keepIf({ workspace: focused.id, root: "", repo: null, branch: null }))
}

export function params(settings: Record<string, unknown>, at: { repo: string | null; branch: string | null } | null) {
  const show = (["branch", "mine", "mentions", "review-requested", "search"].includes(String(settings.show)) ? settings.show : "mine") as Show
  const limit = Number(settings.limit)
  const login = String(settings.login ?? "").trim()
  const base = { limit: Number.isInteger(limit) && limit > 0 ? limit : 10, include: "open-and-merged" as const, ...(login ? { login } : {}) }
  if (show === "branch") return at?.repo && at.branch ? { ...base, show, repo: at.repo, branch: at.branch } : null
  if (show === "search") {
    const query = String(settings.query ?? "").trim()
    return query ? { ...base, show, query } : null
  }
  return { ...base, show }
}

function problem(e: CmuxError | undefined): string {
  // Sandboxed (an unverified install has no network until the person allows it): the runtime's text names the switch.
  if ((e?.details as { sandboxed?: boolean } | undefined)?.sandboxed) return e!.message
  if (e?.code === "integration.unavailable" || e?.code === "integration.not_connected" || e?.code === "scope.missing") {
    return "Sign in to GitHub (gh auth login), or set a GitHub login in this extension's settings for public repositories."
  }
  return e?.message ?? "Unknown error"
}

function open(c: Change) {
  cmux.actions.run("openBrowser", { url: c.url }).catch((e: unknown) => cmux.toast({ title: "Couldn't open the pull request", message: e instanceof Error ? e.message : String(e), tone: "warning" }))
}

function openOnGitHub(c: Change) {
  // The person's default browser, outside cmux.
  cmux.actions.run("openLinkInDefaultBrowser", { url: c.url }).catch(() => open(c))
}

function copyLink(c: Change) {
  cmux
    .call("clipboard.write", { text: c.url })
    .then(() => cmux.toast({ title: "Link copied", message: `${c.repo} #${c.number}`, tone: "success" }))
    .catch((e: unknown) => cmux.toast({ title: "Couldn't copy the link", message: e instanceof Error ? e.message : String(e), tone: "warning" }))
}

function checkOut(c: Change) {
  const at = here()
  const root = at && at.repo === c.repo && at.root ? at.root : null
  const script = checkoutScript(c, root)
  if (!script) return
  cmux.workspace
    .create({ name: `${shortRepo(c.repo)} #${c.number}`, initial_content: "terminal", focus: true, placement: "after_current", argv: ["/bin/sh", "-c", script] })
    .catch((e: unknown) => cmux.toast({ title: "Couldn't check out the pull request", message: e instanceof Error ? e.message : String(e), tone: "warning" }))
}

const menu = (c: () => Change) => [
  Button("Open on GitHub", () => openOnGitHub(c())),
  Button("Copy link", () => copyLink(c())),
  Divider(),
  Button("Check out in a new workspace", () => checkOut(c()))
]

/** The reference: the title, then "cmux #34913  +61,331 −707  2 failing", and a ⋯ menu. */
function railRow(c: () => Change): View {
  return HStack({ spacing: 8 }, [
    Icon(() => symbolOf(c()).symbol).color(() => symbolOf(c()).tone),
    VStack({ spacing: 2, alignment: "leading" }, [
      Text(() => c().title).lineLimit(1).truncation("tail"),
      HStack({ spacing: 6 }, [
        Text(() => `${shortRepo(c().repo)} #${c().number}`).font("caption").color(cmux.theme.text.secondary).lineLimit(1),
        Text(() => `+${grouped(c().additions)}`).font("caption").monospaced().color(cmux.theme.success),
        Text(() => `−${grouped(c().deletions)}`).font("caption").monospaced().color(cmux.theme.danger),
        Text(() => checkLine(c()).text).font("caption").color(() => checkLine(c()).tone).lineLimit(1),
        () => (reviewLine(c()) ? Text(() => reviewLine(c())?.text ?? "").font("caption").color(() => reviewLine(c())?.tone ?? cmux.theme.text.secondary).lineLimit(1) : null)
      ])
    ]).layoutPriority(1),
    Spacer(),
    Menu("⋯", menu(c)).help("More")
  ])
}

/** One line: the title, the line counts and a check dot. */
function compactRow(c: () => Change): View {
  return Row({
    title: () => c().title,
    subtitle: () => `${shortRepo(c().repo)} #${c().number} · +${grouped(c().additions)} −${grouped(c().deletions)} · ${checkLine(c()).text}`,
    symbol: () => symbolOf(c()).symbol,
    tint: () => symbolOf(c()).tone
  })
}

/** A card per pull request on the sidebar's glass. */
function panelRow(c: () => Change): View {
  return Panel({ style: "glass", spacing: 4 }, [
    HStack({ spacing: 6 }, [
      Icon(() => symbolOf(c()).symbol).color(() => symbolOf(c()).tone),
      Text(() => c().title).font("headline").lineLimit(2),
      Spacer(),
      Menu("⋯", menu(c)).help("More")
    ]),
    HStack({ spacing: 8 }, [
      Text(() => `${c().repo} #${c().number}`).font("caption").color(cmux.theme.text.secondary).lineLimit(1),
      Spacer(),
      Text(() => `+${grouped(c().additions)}`).font("caption").monospaced().color(cmux.theme.success),
      Text(() => `−${grouped(c().deletions)}`).font("caption").monospaced().color(cmux.theme.danger)
    ]),
    HStack({ spacing: 8 }, [
      Text(() => checkLine(c()).text).font("caption").color(() => checkLine(c()).tone),
      () => (reviewLine(c()) ? Text(() => reviewLine(c())?.text ?? "").font("caption").color(() => reviewLine(c())?.tone ?? cmux.theme.text.secondary) : null)
    ])
  ])
}

const ROWS: Record<Look, (c: () => Change) => View> = { rail: railRow, compact: compactRow, panel: panelRow }

/** The list itself: mounted only while there is something to read, so no watch runs otherwise. */
function list(wanted: () => NonNullable<ReturnType<typeof params>>, look: () => Look): View {
  const changes = cmux.watch("github.changes", wanted)
  const [more, setMore] = signal(false)
  const all = computed(() => changes.value() ?? [])
  const shown = computed(() => (more() ? all() : all().slice(0, FIRST)))
  const stale = () => changes.status() === "stale" && changes.error() !== undefined
  return VStack({ spacing: 2 }, [
    () => (stale() ? Row({ title: "Couldn't refresh", subtitle: problem(changes.error()), symbol: "exclamationmark.triangle", tint: cmux.theme.warning }).onTap(() => changes.refresh()) : null),
    // A look change rebuilds the rows (each look is its own subtree).
    ForEach({ items: () => [look()], key: (l) => l }, (l) =>
      ForEach({ items: shown, key: (c) => c.id }, (c) =>
        ROWS[l()](c)
          .opacity(() => (stale() ? 0.6 : 1))
          .help(() => `${c().title}\n${c().url}`)
          .onTap(() => open(c()))
          .contextMenu(menu(c))
      )
    ),
    () => (all().length > FIRST ? Button(() => (more() ? "Show less" : "Show more"), () => setMore(!more())).font("caption").color(cmux.theme.text.secondary) : null),
    () => (changes.status() === "loading" ? EmptyState({ title: "Reading pull requests…", symbol: "arrow.triangle.pull" }) : null),
    () => (changes.status() === "error" ? EmptyState({ title: "Can't read pull requests", message: problem(changes.error()), symbol: "exclamationmark.triangle" }) : null),
    () => (changes.status() === "fresh" && all().length === 0 ? EmptyState({ title: "No pull requests", message: "Nothing matches right now.", symbol: "checkmark.circle" }) : null)
  ])
}

export function renderChanges(): View {
  const settings = () => cmux.app.settings() as Record<string, unknown>
  const look = computed<Look>(() => (["rail", "compact", "panel"].includes(String(settings().look)) ? (settings().look as Look) : "rail"))
  // Follow the selected workspace only while the list shows its branch.
  const spaces = workspaces()
  effect(() => {
    if (settings().show === "branch") follow(spaces)
  })
  const wanted = computed(() => params(settings(), here()))
  const on = computed(() => (wanted() ? "on" : "off"))
  return VStack({ spacing: 2 }, [
    ForEach({ items: () => (on() === "on" ? ["on"] : []), key: (k) => k }, () => list(() => wanted() ?? { show: "mine", limit: 1, include: "open-and-merged" }, look)),
    () => (!wanted() && settings().show === "branch" ? EmptyState({ title: "No GitHub branch here", message: "Select a workspace whose folder is a GitHub checkout on a branch.", symbol: "arrow.triangle.branch" }) : null),
    () => (!wanted() && settings().show === "search" ? EmptyState({ title: "No saved search", message: "Set one in Settings > Apps > Changes, for example repo:manaflow-ai/cmux label:bug.", symbol: "magnifyingglass" }) : null)
  ])
}

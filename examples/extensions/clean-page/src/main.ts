// Clean this page: a palette command that asks your own agent which parts of the browser page are
// clutter (ads, consent banners, popups, newsletter prompts, sticky bars, recommended rails), then
// hides them for that site. It imports nothing but the public SDK and ./clean.ts.
// - browserPage().state() gives the tab's address; src/page_read.js, run with browserPage().eval,
//   lists the page's likely clutter. It reads the page and changes nothing.
// - agent.ask sends that list to your default agent, with every tool denied, and the command's
//   gesture: it spends your quota, so it runs only when you pick the command.
// - Only selectors that were in the list are kept, then site.style.set saves them. cmux applies
//   them to the site's open tabs and to every later visit before the page draws, with no model call.
// - Each cleaned site is kept with storage:local too, for the "Sites cleaned" section and its Restore.

import { agent, browserPage, Button, cmux, command, EmptyState, ForEach, HStack, Row, signal, site, Text, VStack, type CommandContext, type View } from "cmux-extension-sdk"
import { buildPrompt, elements, hostOf, keepListed, originOf, parseReply, type Candidate } from "./clean.ts"
// The reader script, as text: browserPage().eval runs it in the page.
import PAGE_READ from "./page_read.js" with { type: "text" }

export interface CleanedSite { origin: string; hide: string[]; unstick: string[]; at: number }

const PREFIX = "site:"
const key = (origin: string) => `${PREFIX}${origin}`
const [sites, setSites] = signal<CleanedSite[] | undefined>(undefined)
const [problem, setProblem] = signal<string | null>(null)
let loading: Promise<CleanedSite[]> | null = null
/** The site the last run said was already clean: running the command again there cleans it fresh. */
let offered: string | null = null

const message = (error: unknown) => (error instanceof Error ? error.message : String(error))
const newestFirst = (list: CleanedSite[]) => [...list].sort((a, b) => b.at - a.at)

/** Reads every cleaned site once; later readers share the copy. */
function load(): Promise<CleanedSite[]> {
  loading ??= (async () => {
    const keys = (await cmux.storage.keys()).filter((k) => k.startsWith(PREFIX))
    const found = (await Promise.all(keys.map((k) => cmux.storage.get<CleanedSite>(k)))).filter((s): s is CleanedSite => !!s && typeof s.origin === "string")
    // A site saved while this read was out stays.
    const merged = new Map(found.map((s) => [s.origin, s]))
    for (const s of sites() ?? []) merged.set(s.origin, s)
    const list = newestFirst([...merged.values()])
    setSites(list)
    return list
  })().catch((error: unknown) => {
    loading = null
    setProblem(message(error))
    return []
  })
  return loading
}

async function remember(site: CleanedSite) {
  await cmux.storage.set(key(site.origin), site)
  setSites((list) => newestFirst([site, ...(list ?? []).filter((s) => s.origin !== site.origin)]))
}

async function forget(origin: string) {
  await cmux.storage.delete(key(origin))
  setSites((list) => (list ?? []).filter((s) => s.origin !== origin))
}

/** What the command answers: the rules it saved, or why it saved none. */
export type CleanResult =
  | { origin: string; hide: string[]; unstick: string[] }
  | { origin: string; already: true; rules: number }
  | { origin: string | null; error: string }

/**
 * The palette command (`local.showcase_clean_page.clean`). `again` cleans a site that is already
 * clean; without it, the first run on such a site says so and a second run cleans it fresh.
 */
export const clean = command(async (args: { again?: boolean }, ctx: CommandContext): Promise<CleanResult> => {
  let read: { url: string; title: string; candidates: Candidate[] }
  let origin: string
  try {
    const browser = browserPage(ctx.cmux)
    const state = await browser.state()
    const found = originOf(state.url)
    if (!found) {
      await cmux.toast({ title: "Open a web page first", tone: "warning" })
      return { origin: null, error: "not a web page" }
    }
    origin = found
    const value = await browser.eval<{ candidates?: Candidate[] } | null>(PAGE_READ, { tab: state.tab })
    read = { url: state.url, title: state.title, candidates: Array.isArray(value?.candidates) ? value.candidates : [] }
  } catch (error) {
    await cmux.toast({ title: "Couldn't read this page", message: message(error), tone: "warning" })
    return { origin: null, error: message(error) }
  }
  const host = hostOf(origin)
  await load()
  // The live list, not the first read: a site saved since then is in it.
  const saved = (sites() ?? []).find((s) => s.origin === origin)
  if (saved && !args?.again && offered !== origin) {
    offered = origin
    const rules = saved.hide.length + saved.unstick.length
    await cmux.toast({ title: `${host} is already clean`, message: `${elements(rules)} hidden or unstuck. Run Clean this page again to clean it fresh.` })
    return { origin, already: true, rules }
  }
  offered = null
  if (read.candidates.length === 0) {
    await cmux.toast({ title: `Nothing to clean on ${host}`, tone: "warning" })
    return { origin, error: "no candidates" }
  }

  let reply
  try {
    reply = await agent.ask({ prompt: buildPrompt(read) }, { gesture: ctx.gesture })
  } catch (error) {
    await cmux.toast({ title: `Couldn't clean ${host}`, message: message(error), tone: "danger" })
    return { origin, error: message(error) }
  }
  const picks = parseReply(reply.text)
  if (!picks) {
    await cmux.toast({ title: `Couldn't clean ${host}`, message: "The agent's answer had no list of elements.", tone: "danger" })
    return { origin, error: "unreadable reply" }
  }
  const kept = keepListed(picks, read.candidates)
  const count = kept.hide.length + kept.unstick.length
  try {
    await site.style.set({ origin, hide: kept.hide, unstick: kept.unstick })
    if (count === 0) {
      if (saved) await forget(origin)
    } else {
      await remember({ origin, ...kept, at: Date.now() })
    }
  } catch (error) {
    await cmux.toast({ title: `Couldn't clean ${host}`, message: message(error), tone: "danger" })
    return { origin, error: message(error) }
  }
  if (count === 0) {
    await cmux.toast({ title: `Nothing to clean on ${host}` })
    return { origin, ...kept }
  }
  await cmux.toast({ title: `Cleaned ${elements(count)} on ${host}`, tone: "success" })
  return { origin, ...kept }
})

/** Puts a site back as it was: no rules for it, and it leaves the list. */
export async function restore(origin: string) {
  try {
    await site.style.set({ origin, hide: [], unstick: [] })
    await forget(origin)
    setProblem(null)
  } catch (error) {
    setProblem(message(error))
  }
}

/** "4 hidden · 1 unstuck". */
export function summary(site: CleanedSite): string {
  const parts: string[] = []
  if (site.hide.length) parts.push(`${site.hide.length} hidden`)
  if (site.unstick.length) parts.push(`${site.unstick.length} unstuck`)
  return parts.join(" · ")
}

export function renderSites(): View {
  void load()
  const list = () => sites() ?? []
  return VStack({ spacing: 2 }, [
    ForEach({ items: list, key: (s) => s.origin }, (s) =>
      HStack({ spacing: 6 }, [
        Row({
          title: () => hostOf(s().origin),
          subtitle: () => summary(s()),
          symbol: "sparkles"
        }),
        Button("Restore", () => restore(s().origin))
      ])
    ),
    () =>
      sites() && sites()!.length === 0
        ? EmptyState({ title: "No sites cleaned", message: "Open a page, then run Clean this page from the command palette.", symbol: "sparkles" })
        : null,
    () => (problem() ? Text(() => `Couldn't update: ${problem()}`).font("caption").color(cmux.theme.warning) : null)
  ])
}

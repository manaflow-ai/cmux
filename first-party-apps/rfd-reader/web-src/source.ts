// Where RFDs come from: GitHub, read through cmux's GitHub gateway (`integration.request`), which
// runs `gh api` as the person's own sign-in with an ETag cache, so a re-read that changed nothing
// is a free 304. Reads happen when the pane opens and when the person asks (Refresh); nothing
// here polls. Bodies are kept in app storage by blob sha (a sha's text never changes), so a
// second open reads only the listing.
import { meta, noteMeta, parseNoteName, parseRfdName, toNote, toRfd, type Note, type NoteMeta, type Rfd, type RfdMeta, type ReviewComment } from "./model"

export interface Host {
  get<T>(path: string): Promise<T>
  load<T>(key: string): Promise<T | null>
  save(key: string, value: unknown): Promise<void>
}

export interface Config {
  repo: string
  dir: string
  branch: string
}

export const DEFAULT_CONFIG: Config = { repo: "manaflow-ai/cmuxterm-hq", dir: "docs/rfd", branch: "main" }

type ContentEntry = { name: string; path: string; sha: string; type: string }
type Pull = { number: number; title: string; body: string | null; html_url: string; updated_at: string; head: { ref: string; sha: string } }
type PullFile = { filename: string; sha: string; status: string }

/** At most `n` reads at once: the gateway runs at most 8 `gh` for every app together. */
async function each<T, R>(items: T[], n: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length)
  let next = 0
  await Promise.all(
    Array.from({ length: Math.min(n, items.length) }, async () => {
      while (next < items.length) {
        const i = next++
        out[i] = await fn(items[i])
      }
    }),
  )
  return out
}

function decodeBase64(b64: string): string {
  const bin = atob(b64.replace(/\s+/g, ""))
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return new TextDecoder().decode(bytes)
}

/** Pages of a GitHub list read until a short page; at most `max` pages (100 items each). */
async function pages<T>(host: Host, path: string, max = 10): Promise<T[]> {
  const out: T[] = []
  for (let page = 1; page <= max; page++) {
    const items = await host.get<T[]>(`${path}${path.includes("?") ? "&" : "?"}per_page=100&page=${page}`)
    out.push(...items)
    if (items.length < 100) break
  }
  return out
}

const isNotFound = (e: unknown) => /not.?found|404/i.test(String((e as { code?: string })?.code ?? "") + String(e))

export class Source {
  private bodies = new Map<string, Rfd>()

  constructor(
    private host: Host,
    readonly config: Config,
  ) {}

  private repoPath = (rest: string) => `/repos/${this.config.repo}/${rest}`

  /** The list kept from the last read, for an instant first frame. */
  async cachedIndex(): Promise<RfdMeta[]> {
    return (await this.host.load<RfdMeta[]>(this.key("index"))) ?? []
  }

  private key = (k: string) => `${this.config.repo}:${this.config.dir}:${k}`

  /** One RFD's text by its blob sha: from memory, app storage, or one blob read. */
  async rfd(m: Pick<RfdMeta, "path" | "sha" | "updated" | "pr">): Promise<Rfd> {
    // Number, title, state, authors and links come from the text; the date and the pull request
    // from where it was found.
    const at = (r: Rfd): Rfd => ({ ...r, updated: m.updated || r.updated, pr: m.pr })
    const hit = this.bodies.get(m.sha)
    if (hit) return at(hit)
    let text = await this.host.load<string>(`blob:${m.sha}`)
    if (text == null) {
      const blob = await this.host.get<{ content: string }>(this.repoPath(`git/blobs/${m.sha}`))
      text = decodeBase64(blob.content)
      await this.host.save(`blob:${m.sha}`, text).catch(() => undefined)
    }
    const rfd = toRfd(m.path, m.sha, text, m.updated)
    if (!rfd) throw new Error(`${m.path} is not an RFD file`)
    this.bodies.set(m.sha, rfd)
    return at(rfd)
  }

  /** The folder on the base branch, and every open pull request that adds or changes an RFD. */
  async index(): Promise<{ rfds: RfdMeta[]; missingFolder: boolean }> {
    const { dir, branch } = this.config
    let missingFolder = false
    const files = await this.host
      .get<ContentEntry[]>(this.repoPath(`contents/${dir}?ref=${encodeURIComponent(branch)}`))
      .catch((e) => {
        if (isNotFound(e)) {
          missingFolder = true
          return [] as ContentEntry[]
        }
        throw e
      })
    const onBase = files.filter((f) => f.type === "file" && parseRfdName(f.name))

    const pulls = await pages<Pull>(this.host, this.repoPath("pulls?state=open"))
    const rfdPulls = pulls.filter((p) => /\bRFD\b/i.test(p.title) || (p.body ?? "").includes(`${dir}/`))
    const pullFiles = await each(rfdPulls, 4, async (p) => {
      // A failed read fails the refresh, which keeps the last list, rather than saving one without this PR.
      const changed = await pages<PullFile>(this.host, this.repoPath(`pulls/${p.number}/files`), 30)
      return changed
        .filter((f) => f.status !== "removed" && f.filename.startsWith(`${dir}/`) && parseRfdName(f.filename.slice(dir.length + 1)))
        .map((f) => ({ path: f.filename, sha: f.sha, pr: { number: p.number, url: p.html_url, head: p.head.ref, updatedAt: p.updated_at } }))
    })

    const byNumber = new Map<number, { path: string; sha: string; pr?: RfdMeta["pr"] }>()
    for (const f of onBase) byNumber.set(parseRfdName(f.name)!.number, { path: f.path, sha: f.sha })
    // A pull request's text is the newest: it shows what is being discussed now.
    for (const f of pullFiles.flat()) byNumber.set(parseRfdName(f.path.split("/").pop()!)!.number, f)

    const rfds = await each([...byNumber.values()], 4, async (f) => {
      const rfd = await this.rfd({ ...f, updated: "" })
      let updated = rfd.updated
      if (!updated && !f.pr) updated = await this.lastCommitDate(f.path, f.sha)
      return meta({ ...rfd, updated, pr: f.pr })
    })
    await this.host.save(this.key("index"), rfds).catch(() => undefined)
    return { rfds, missingFolder }
  }

  /** The date of the newest commit to a file, kept by its blob sha. */
  private async lastCommitDate(path: string, sha: string): Promise<string> {
    const kept = await this.host.load<string>(`date:${sha}`)
    if (kept !== null) return kept
    const commits = await this.host
      .get<Array<{ commit: { committer: { date: string } } }>>(this.repoPath(`commits?path=${encodeURIComponent(path)}&sha=${encodeURIComponent(this.config.branch)}&per_page=1`))
      .catch(() => [])
    const date = commits[0]?.commit.committer.date ?? ""
    // Kept even when empty: a sha whose history is unreadable is not asked again.
    await this.host.save(`date:${sha}`, date).catch(() => undefined)
    return date
  }

  /** The pull request an RFD is discussed in: its open one, else the first PR link in its front matter. */
  prOf(r: RfdMeta): number | null {
    if (r.pr) return r.pr.number
    for (const l of r.links) {
      const m = /github\.com\/([^/]+\/[^/]+)\/pull\/(\d+)/.exec(l)
      if (m && m[1].toLowerCase() === this.config.repo.toLowerCase()) return Number(m[2])
    }
    return null
  }

  /** The review comments of that pull request (read after the text is on screen). */
  async comments(r: RfdMeta): Promise<{ pr: number | null; comments: ReviewComment[] }> {
    const pr = this.prOf(r)
    if (pr === null) return { pr, comments: [] }
    const comments = await pages<ReviewComment>(this.host, this.repoPath(`pulls/${pr}/comments`))
    return { pr, comments }
  }

  /** The signed-in login, for a new RFD's authors. */
  async login(): Promise<string> {
    const kept = await this.host.load<string>("login")
    if (kept) return kept
    const user = await this.host.get<{ login: string }>("/user").catch(() => null)
    if (user?.login) await this.host.save("login", user.login).catch(() => undefined)
    return user?.login ?? ""
  }
}

// ---- Reading notes ------------------------------------------------------------------------

export const NOTES_DIR = "docs/reading"

/**
 * Reading notes (`docs/reading/YYYY-MM-DD-slug.md`) in the same repository, read the same way as
 * RFDs: the folder on the base branch, then every open pull request that adds or changes a note.
 * A refresh costs the folder, the open pull requests and the files of each note pull request; a
 * note's text is read once per blob sha.
 */
export class NoteSource {
  private bodies = new Map<string, Note>()

  constructor(
    private host: Host,
    readonly config: Config,
    readonly dir = NOTES_DIR,
  ) {}

  private repoPath = (rest: string) => `/repos/${this.config.repo}/${rest}`
  private key = (k: string) => `${this.config.repo}:${this.dir}:${k}`

  async cachedIndex(): Promise<NoteMeta[]> {
    return (await this.host.load<NoteMeta[]>(this.key("index"))) ?? []
  }

  private async text(sha: string): Promise<string> {
    let text = await this.host.load<string>(`blob:${sha}`)
    if (text == null) {
      const blob = await this.host.get<{ content: string }>(this.repoPath(`git/blobs/${sha}`))
      text = decodeBase64(blob.content)
      await this.host.save(`blob:${sha}`, text).catch(() => undefined)
    }
    return text
  }

  /** One note's text by its blob sha: from memory, app storage, or one blob read. */
  async note(m: Pick<NoteMeta, "path" | "sha" | "pr" | "indexed">): Promise<Note> {
    const at = (n: Note): Note => ({ ...n, pr: m.pr, indexed: m.indexed })
    const hit = this.bodies.get(m.sha)
    if (hit) return at(hit)
    const note = toNote(m.path, m.sha, await this.text(m.sha))
    if (!note) throw new Error(`${m.path} is not a reading note`)
    this.bodies.set(m.sha, note)
    return at(note)
  }

  /** `_template.md`'s text, for a new note's sections; undefined when the folder has none. */
  template?: { path: string; sha: string }

  async templateText(): Promise<string | undefined> {
    return this.template ? this.text(this.template.sha).catch(() => undefined) : undefined
  }

  /** The index (README.md) on the base branch, for a new note's row. */
  readme?: { path: string; sha: string }

  async readmeText(): Promise<string | undefined> {
    return this.readme ? this.text(this.readme.sha).catch(() => undefined) : undefined
  }

  async index(): Promise<{ notes: NoteMeta[]; missingFolder: boolean }> {
    const { branch } = this.config
    const dir = this.dir
    let missingFolder = false
    const files = await this.host
      .get<ContentEntry[]>(this.repoPath(`contents/${dir}?ref=${encodeURIComponent(branch)}`))
      .catch((e) => {
        if (isNotFound(e)) {
          missingFolder = true
          return [] as ContentEntry[]
        }
        throw e
      })
    const file = (name: string) => files.find((f) => f.type === "file" && f.name === name)
    const t = file("_template.md")
    this.template = t ? { path: t.path, sha: t.sha } : undefined
    const r = file("README.md")
    this.readme = r ? { path: r.path, sha: r.sha } : undefined
    const onBase = files.filter((f) => f.type === "file" && parseNoteName(f.name))

    const pulls = await pages<Pull>(this.host, this.repoPath("pulls?state=open"))
    const notePulls = pulls.filter((p) => /reading note/i.test(p.title) || /\d{4}-\d{2}-\d{2}-[a-z0-9-]+\.md/.test(p.title) || (p.body ?? "").includes(`${dir}/`))
    const pullFiles = await each(notePulls, 4, async (p) => {
      const changed = await pages<PullFile>(this.host, this.repoPath(`pulls/${p.number}/files`), 30)
      const indexed = changed.some((f) => f.filename === `${dir}/README.md` && f.status !== "removed")
      return changed
        .filter((f) => f.status !== "removed" && f.filename.startsWith(`${dir}/`) && parseNoteName(f.filename.slice(dir.length + 1)))
        .map((f) => ({ path: f.filename, sha: f.sha, indexed, pr: { number: p.number, url: p.html_url, head: p.head.ref, updatedAt: p.updated_at } }))
    })

    const byId = new Map<string, { path: string; sha: string; pr?: NoteMeta["pr"]; indexed?: boolean }>()
    for (const f of onBase) byId.set(parseNoteName(f.name)!.id, { path: f.path, sha: f.sha })
    // A pull request's text is the newest.
    for (const f of pullFiles.flat()) byId.set(parseNoteName(f.path.split("/").pop()!)!.id, f)

    const notes = await each([...byId.values()], 4, async (f) => noteMeta(await this.note(f)))
    await this.host.save(this.key("index"), notes).catch(() => undefined)
    return { notes, missingFolder }
  }

  /**
   * The pull request a note is discussed in: its open one, else the one that last changed it (the
   * `(#N)` a squash merge puts in its newest commit's subject), kept by blob sha.
   */
  async prOf(n: NoteMeta): Promise<number | null> {
    if (n.pr) return n.pr.number
    const kept = await this.host.load<number>(`notepr:${n.sha}`)
    if (kept !== null) return kept || null
    const commits = await this.host
      .get<Array<{ commit: { message: string } }>>(this.repoPath(`commits?path=${encodeURIComponent(n.path)}&sha=${encodeURIComponent(this.config.branch)}&per_page=1`))
      .catch(() => [])
    const subject = commits[0]?.commit.message?.split("\n")[0] ?? ""
    const pr = Number(/\(#(\d+)\)\s*$/.exec(subject)?.[1] ?? 0)
    await this.host.save(`notepr:${n.sha}`, pr).catch(() => undefined)
    return pr || null
  }

  async comments(n: NoteMeta): Promise<{ pr: number | null; comments: ReviewComment[] }> {
    const pr = await this.prOf(n)
    if (pr === null) return { pr, comments: [] }
    return { pr, comments: await pages<ReviewComment>(this.host, this.repoPath(`pulls/${pr}/comments`)) }
  }
}

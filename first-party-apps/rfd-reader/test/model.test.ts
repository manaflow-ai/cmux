import { describe, expect, test } from "bun:test"
import { blockForLine, byRead, byUpdated, isSafeHref, jump, jumpNotes, linkKind, newFileUrl, newNoteFileUrl, newNoteText, noteFileName, noteIndexRow, noteOfHref, noteTemplateBody, NOTE_TEMPLATE_BODY, openableUrl, newRfdText, nextNumber, parseNoteName, searchNotes, tagCounts, templateBody, toc, toNote, TEMPLATE_BODY, parseFrontMatter, parseRfdName, renderBlocks, rfdOfHref, rfdRefs, search, threads, toRfd, withIndexRow } from "../web-src/model"
import { NoteSource, Source, type Host } from "../web-src/source"
import { COMMENTS, FILES, NOTE_FILES, NOTE_PR_FILE, NOTE_README, NOTE_TEMPLATE, PR_FILE, TEMPLATE, answer } from "../preview/fixtures"

const all = () => [...Object.entries(FILES).map(([p, f]) => toRfd(p, f.sha, f.text, f.date)!), toRfd(PR_FILE.path, PR_FILE.sha, PR_FILE.text)!]

describe("files and front matter", () => {
  test("only NNNN-slug.md names are RFDs", () => {
    expect(parseRfdName("0002-earned-access-ladder.md")).toEqual({ number: 2, slug: "earned-access-ladder" })
    expect(parseRfdName("README.md")).toBeNull()
    expect(parseRfdName("0002-earned-access-ladder")).toBeNull()
  })

  test("front matter: scalars, lists, inline lists, and the lines it took", () => {
    const { data, body, lines } = parseFrontMatter("---\nstate: discussion\nauthors:\n  - a\n  - \"b c\"\nlinks: [x, y]\n---\n\n# RFD 0009: T\n")
    expect(data).toEqual({ state: "discussion", authors: ["a", "b c"], links: ["x", "y"] })
    expect(lines).toBe(7)
    expect(body.startsWith("\n# RFD 0009")).toBe(true)
  })

  test("an RFD reads its title from the heading and its date from last_updated", () => {
    const r = toRfd(PR_FILE.path, PR_FILE.sha, PR_FILE.text)!
    expect(r).toMatchObject({ number: 2, title: "An access ladder for agents", state: "discussion", authors: ["claude (access lane)"], updated: "2026-11-17" })
  })

  test("the list is newest first, a pull request's update counting", () => {
    const metas = all().map((r, i) => (r.number === 2 ? { ...r, pr: { number: 1, url: "", head: "", updatedAt: "2026-11-17T08:12:00Z" } } : r))
    expect(metas.sort(byUpdated).map((r) => r.number)).toEqual([2, 3, 1, 4])
  })
})

describe("rendering", () => {
  test("each block knows its file lines, front matter included", () => {
    const r = toRfd(PR_FILE.path, PR_FILE.sha, PR_FILE.text)!
    const blocks = renderBlocks(r)
    const lines = PR_FILE.text.split("\n")
    for (const b of blocks) {
      const first = lines[b.from - 1]
      // The block's first file line is in its HTML (headings and paragraphs keep their words).
      const word = first.replace(/^\s*\d+\./, "").replace(/[#|`*-]/g, " ").trim().split(/\s+/)[0]
      if (word) expect(b.html).toContain(word)
    }
    expect(blocks[0].heading).toEqual({ depth: 1, text: "RFD 0002: An access ladder for agents" })
  })

  test("raw HTML in a file is shown, not run", () => {
    const blocks = renderBlocks({ body: "<script>alert(1)</script>\n\nhi <b>x</b>\n", bodyLineOffset: 0 })
    expect(blocks.map((b) => b.html).join("")).not.toContain("<script>")
    expect(blocks.map((b) => b.html).join("")).not.toContain("<b>")
  })

  test("references to other RFDs", () => {
    expect(rfdRefs("see RFD 2 and RFD-0013, and docs/rfd/0004-x.md")).toEqual([2, 13, 4])
    expect(rfdOfHref("0002-agent-access-ladder.md")).toBe(2)
    expect(rfdOfHref("https://github.com/o/r/blob/main/docs/rfd/0011-a.md#x")).toBe(11)
    expect(rfdOfHref("https://example.com")).toBeNull()
  })
})

describe("review comments", () => {
  test("threads keep replies and drop outdated comments", () => {
    const ts = threads(COMMENTS as never, PR_FILE.path)
    expect(ts.map((t) => [t.line, t.comments.length])).toEqual([
      [18, 2],
      [43, 1],
    ])
    expect(threads(COMMENTS as never, "docs/rfd/other.md")).toEqual([])
  })

  test("a thread sits beside the block holding its line", () => {
    const r = toRfd(PR_FILE.path, PR_FILE.sha, PR_FILE.text)!
    const blocks = renderBlocks(r)
    const lines = PR_FILE.text.split("\n")
    expect(lines[17]).toContain("pull requests start the same way")
    expect(blocks[blockForLine(blocks, 18)].html).toContain("fifty clean")
    expect(blocks[blockForLine(blocks, 43)].html).toContain("approve-all")
  })
})

describe("search and jump-to", () => {
  test("full text: every term must match, titles first", () => {
    const hits = search(all(), "ladder promotion")
    expect(hits.map((h) => h.number)).toEqual([2])
    expect(hits[0].excerpt).toContain("«")
    expect(search(all(), "sidebar")[0].number).toBe(3)
    expect(search(all(), "nothing-like-this")).toEqual([])
  })

  test("jump by number or title", () => {
    expect(jump(all(), "2")[0].number).toBe(2)
    expect(jump(all(), "0003")[0].number).toBe(3)
    expect(jump(all(), "session row").map((r) => r.number)).toEqual([3])
  })
})

describe("a new RFD", () => {
  test("takes the next number and opens GitHub's new-file page filled in", () => {
    const n = nextNumber(all())
    expect(n).toBe(5)
    const text = newRfdText({ number: n, title: "Reader for RFDs", state: "discussion", authors: ["leo"], today: "2026-11-17" })
    expect(parseFrontMatter(text).data).toMatchObject({ state: "discussion", authors: ["leo"] })
    expect(toRfd("docs/rfd/0005-reader-for-rfds.md", "x", text)!.title).toBe("Reader for RFDs")
    const url = new URL(newFileUrl("o/r", "main", "docs/rfd", n, "Reader for RFDs", text))
    expect(url.pathname).toBe("/o/r/new/main")
    expect(url.searchParams.get("filename")).toBe("docs/rfd/0005-reader-for-rfds.md")
    expect(url.searchParams.get("value")).toBe(text)
  })
})

describe("the source", () => {
  const host = () => {
    const reads: string[] = []
    const store = new Map<string, unknown>()
    const h: Host = {
      async get<T>(path: string) {
        reads.push(path)
        return structuredClone(answer(path)) as T
      },
      async load<T>(k: string) {
        return (store.get(k) as T) ?? null
      },
      async save(k, v) {
        store.set(k, v)
      },
    }
    return { h, reads }
  }

  test("lists the base branch and the RFDs on open pull requests", async () => {
    const { h } = host()
    const { rfds } = await new Source(h, { repo: "manaflow-ai/cmuxterm-hq", dir: "docs/rfd", branch: "main" }).index()
    expect(rfds.map((r) => r.number).sort()).toEqual([0, 1, 2, 3, 4])
    const two = rfds.find((r) => r.number === 2)!
    expect(two.pr?.number).toBe(12392)
    expect(rfds.find((r) => r.number === 1)!.updated).toBe("2026-11-10T18:00:00Z")
  })

  test("a second read fetches no bodies or dates again (they are kept by sha)", async () => {
    const { h, reads } = host()
    const config = { repo: "manaflow-ai/cmuxterm-hq", dir: "docs/rfd", branch: "main" }
    await new Source(h, config).index()
    const first = reads.length
    await new Source(h, config).index()
    const second = reads.slice(first)
    expect(second.some((p) => p.includes("git/blobs") || p.includes("commits?"))).toBe(false)
    // listing, open pulls, and the one RFD pull's files
    expect(second.length).toBe(3)
  })

  test("comments come from the open pull request, else the front matter's PR link", async () => {
    const { h } = host()
    const src = new Source(h, { repo: "manaflow-ai/cmuxterm-hq", dir: "docs/rfd", branch: "main" })
    const { rfds } = await src.index()
    expect((await src.comments(rfds.find((r) => r.number === 2)!)).pr).toBe(12392)
    expect(src.prOf(rfds.find((r) => r.number === 1)!)).toBe(12001)
    expect((await src.comments(rfds.find((r) => r.number === 3)!)).pr).toBeNull()
  })
})

describe("the header and contents (RFD 26's shape)", () => {
  test("access and links: the discussion, a recording, another RFD", () => {
    const r = toRfd(PR_FILE.path, PR_FILE.sha, PR_FILE.text)!
    expect(r.access).toBe("internal")
    expect(r.links.map((l) => linkKind(l).kind)).toEqual(["discussion", "recording", "rfd"])
    expect(linkKind(r.links[0]).label).toBe("Discussion #12392")
    expect(linkKind("https://docs.example.com/x").label).toBe("docs.example.com")
  })

  test("contents lists the five body sections in order, with the options under theirs", () => {
    const r = toRfd(PR_FILE.path, PR_FILE.sha, PR_FILE.text)!
    expect(toc(renderBlocks(r)).filter((c) => c.depth === 2).map((c) => c.text)).toEqual(["Problem and context", "Options", "Goals", "The options against the goals", "Determination"])
    expect(toc(renderBlocks(r)).filter((c) => c.depth === 3).map((c) => c.text)).toEqual(["Earned rungs", "Per-project policy"])
  })

  test("a new RFD starts from the repository's template body, else the built-in one", () => {
    const body = templateBody(TEMPLATE.text)
    expect(body.startsWith("## Problem and context")).toBe(true)
    expect(body).toContain("Not under consideration:")
    expect(body).not.toContain("# RFD NNNN")
    expect(templateBody(undefined)).toBe(TEMPLATE_BODY)
    const text = newRfdText({ number: 5, title: "T", state: "discussion", authors: [], template: body, today: "2026-11-17" })
    const r = toRfd("docs/rfd/0005-t.md", "x", text)!
    expect(r.access).toBe("internal")
    expect(toc(renderBlocks(r)).filter((c) => c.depth === 2).length).toBe(5)
  })
})

describe("review fixes", () => {
  test("links and images with active schemes render as text and never open", () => {
    const body = "[a](javascript:alert(1)) [b](JaVa\tScRiPt:alert(1)) [c](data:text/html,x) ![d](javascript:x) [ok](https://example.com/x) [rel](0003-x.md) [frag](#goals)\n"
    const html = renderBlocks({ body, bodyLineOffset: 0 }).map((b) => b.html).join("")
    expect(html.toLowerCase()).not.toContain("javascript")
    expect(html).not.toContain("data:text")
    expect(html).toContain('href="https://example.com/x"')
    expect(html).toContain('href="0003-x.md"')
    expect(html).toContain('href="#goals"')
    expect(isSafeHref("mailto:a@b.c")).toBe(true)
    expect(isSafeHref(" javascript:x")).toBe(false)
    expect(openableUrl("javascript:alert(1)", "https://github.com/")).toBeNull()
    expect(openableUrl("data:text/html,x", "https://github.com/")).toBeNull()
    expect(openableUrl("mailto:a@b.c", "https://github.com/")).toBeNull()
    expect(openableUrl("../x.md", "https://github.com/o/r/blob/main/docs/rfd/")).toBe("https://github.com/o/r/blob/main/docs/x.md")
  })

  test("search finds text that is only in a code block", () => {
    const r = toRfd("docs/rfd/0009-c.md", "c", "---\nstate: ideation\n---\n\n# RFD 0009: Code\n\nProse.\n\n```sh\ncmux frobnicate --now\n```\n")!
    expect(search([r], "frobnicate").map((h) => h.number)).toEqual([9])
  })

  const pagedHost = (pullFiles: (page: number) => unknown) => {
    const reads: string[] = []
    const store = new Map<string, unknown>()
    const h: Host = {
      async get<T>(path: string) {
        reads.push(path)
        const page = Number(/[?&]page=(\d+)/.exec(path)?.[1] ?? 1)
        if (path.includes("/pulls?")) return (page === 1 ? Array.from({ length: 100 }, (_, i) => ({ number: 90000 + i, title: "x", body: "", html_url: "", updated_at: "", head: { ref: "", sha: "" } })) : [{ number: 12392, title: "RFD 0002", body: "", html_url: "u", updated_at: "2026-11-17T08:12:00Z", head: { ref: "h", sha: "s" } }]) as T
        if (path.includes("/pulls/12392/files")) return pullFiles(page) as T
        return structuredClone(answer(path)) as T
      },
      async load<T>(k: string) {
        return (store.get(k) as T) ?? null
      },
      async save(k, v) {
        store.set(k, v)
      },
    }
    return { h, reads, store }
  }
  const config = { repo: "manaflow-ai/cmuxterm-hq", dir: "docs/rfd", branch: "main" }

  test("list reads follow pages: a pull request past the first hundred is found", async () => {
    const { h, reads } = pagedHost(() => [{ filename: PR_FILE.path, sha: PR_FILE.sha, status: "added" }])
    const { rfds } = await new Source(h, config).index()
    expect(reads.filter((p) => p.includes("/pulls?")).length).toBe(2)
    expect(rfds.find((r) => r.number === 2)!.pr?.number).toBe(12392)
  })

  test("a failed pull request read fails the refresh and keeps the last list", async () => {
    const { h, store } = pagedHost(() => {
      throw new Error("rate limited")
    })
    store.set(`${config.repo}:${config.dir}:index`, [{ number: 7 }])
    await expect(new Source(h, config).index()).rejects.toThrow("rate limited")
    expect(store.get(`${config.repo}:${config.dir}:index`)).toEqual([{ number: 7 }])
  })
})

describe("reading notes", () => {
  const notesOf = () => [...Object.entries(NOTE_FILES).map(([p, f]) => toNote(p, f.sha, f.text)!), toNote(NOTE_PR_FILE.path, NOTE_PR_FILE.sha, NOTE_PR_FILE.text)!]

  test("only YYYY-MM-DD-slug.md names are notes: the index and the template are not", () => {
    expect(parseNoteName("2026-11-18-google-abfs.md")).toEqual({ id: "2026-11-18-google-abfs", date: "2026-11-18", slug: "google-abfs" })
    expect(parseNoteName("README.md")).toBeNull()
    expect(parseNoteName("_template.md")).toBeNull()
    expect(parseNoteName("0002-earned-access-ladder.md")).toBeNull()
  })

  test("a note reads every front matter field, its title from the heading", () => {
    const n = toNote("docs/reading/2026-11-18-lazy-checkouts.md", "x", NOTE_FILES["docs/reading/2026-11-18-lazy-checkouts.md"].text)!
    expect(n).toMatchObject({
      id: "2026-11-18-lazy-checkouts",
      title: "Lazy git checkouts with content-checked caching",
      state: "acting",
      source: "https://example.com/blog/lazy-git-checkouts",
      sourceAuthor: "The build team (Example Co)",
      published: "2026-11-17",
      read: "2026-11-18",
      sharedBy: "Leo",
      ask: "hey this came out recently",
      access: "internal",
      tags: ["git", "ci", "projection"],
      links: ["https://github.com/manaflow-ai/cmuxterm-hq/pull/13166"],
    })
  })

  test("an ask with quotes inside keeps them", () => {
    const n = toNote("docs/reading/2026-11-18-x.md", "x", `---\nstate: read\nask: "https://a.example what do we think" and later "https://b.example"\n---\n\n# X\n`)!
    expect(n.ask).toBe(`https://a.example what do we think" and later "https://b.example`)
  })

  test("the list is newest read first", () => {
    expect(notesOf().sort(byRead).map((n) => n.read)).toEqual(["2026-11-18", "2026-11-17", "2026-11-16", "2026-11-10"])
  })

  test("a link to a note is a note, never RFD 2026", () => {
    expect(noteOfHref("../reading/2026-11-16-session-pools.md")).toBe("2026-11-16-session-pools")
    expect(noteOfHref("https://github.com/o/r/blob/main/docs/reading/2026-11-16-session-pools.md#x")).toBe("2026-11-16-session-pools")
    expect(rfdOfHref("../reading/2026-11-16-session-pools.md")).toBeNull()
    expect(rfdOfHref("../rfd/0002-agent-access-ladder.md")).toBe(2)
    expect(rfdRefs("docs/reading/2026-11-16-x.md and RFD 7")).toEqual([7])
    expect(linkKind("../reading/2026-11-16-session-pools.md").kind).toBe("note")
  })

  test("search and jump-to cover notes: tags and titles weigh most", () => {
    const hits = searchNotes(notesOf(), "ci")
    expect(hits.map((h) => h.id).slice(0, 2).sort()).toEqual(["2026-11-17-verification", "2026-11-18-lazy-checkouts"])
    expect(searchNotes(notesOf(), "warm pool").map((h) => h.id)).toEqual(["2026-11-16-session-pools"])
    expect(jumpNotes(notesOf(), "lazy").map((n) => n.id)).toEqual(["2026-11-18-lazy-checkouts"])
    expect(jumpNotes(notesOf(), "2026-11-10").map((n) => n.id)).toEqual(["2026-11-10-old-browser-post"])
    expect(tagCounts(notesOf())[0]).toEqual(["ci", 2])
  })

  test("a new note starts from _template.md's sections and has its index row", () => {
    const body = noteTemplateBody(NOTE_TEMPLATE.text)
    expect(body.startsWith("## What it says")).toBe(true)
    expect(body).not.toContain("<!--")
    expect(body).not.toContain("# Title")
    expect(noteTemplateBody(undefined)).toBe(NOTE_TEMPLATE_BODY)
    const f = { title: "How one team verifies", state: "read", source: "https://example.com/v", sourceAuthor: "Alex Kim (Example Labs)", published: "2026-11-16", read: "2026-11-17", readBy: "review lane", sharedBy: "Leo", ask: "what do u think", tags: ["review", "ci"] }
    const text = newNoteText({ ...f, template: body })
    const file = noteFileName(f.read, f.title)
    expect(file).toBe("2026-11-17-how-one-team-verifies.md")
    const n = toNote(`docs/reading/${file}`, "x", text)!
    expect(n).toMatchObject({ title: f.title, state: "read", source: f.source, sourceAuthor: f.sourceAuthor, read: f.read, ask: f.ask, tags: f.tags, access: "internal" })
    expect(toc(renderBlocks(n)).map((c) => c.text)).toEqual(["What it says", "What we already do", "What we take from it", "What we did"])
    const row = noteIndexRow({ ...f, file })
    expect(row).toBe("| 2026-11-17 | [How one team verifies](2026-11-17-how-one-team-verifies.md) | Example Labs, example.com | read | review, ci |")
    const readme = withIndexRow(NOTE_README.text, row)!
    const lines = readme.split("\n")
    expect(lines[lines.findIndex((l) => l.startsWith("| ---")) + 1]).toBe(row)
    expect(withIndexRow("# no table\n", row)).toBeNull()
    const url = new URL(newNoteFileUrl("o/r", "main", "docs/reading", file, text))
    expect(url.searchParams.get("filename")).toBe("docs/reading/2026-11-17-how-one-team-verifies.md")
    expect(url.searchParams.get("value")).toBe(text)
  })

  test("the source lists the folder (no README or template) and the notes on open pull requests", async () => {
    const reads: string[] = []
    const store = new Map<string, unknown>()
    const h: Host = {
      async get<T>(path: string) {
        reads.push(path)
        return structuredClone(answer(path)) as T
      },
      async load<T>(k: string) {
        return (store.get(k) as T) ?? null
      },
      async save(k, v) {
        store.set(k, v)
      },
    }
    const src = new NoteSource(h, { repo: "manaflow-ai/cmuxterm-hq", dir: "docs/rfd", branch: "main" })
    const { notes } = await src.index()
    expect(notes.map((n) => n.id).sort()).toEqual(["2026-11-10-old-browser-post", "2026-11-16-session-pools", "2026-11-17-verification", "2026-11-18-lazy-checkouts"])
    const pr = notes.find((n) => n.id === "2026-11-17-verification")!
    expect(pr.pr?.number).toBe(12410)
    expect(pr.indexed).toBe(false)
    expect(notes.find((n) => n.id === "2026-11-18-lazy-checkouts")!.pr).toBeUndefined()
    expect((await src.templateText())?.includes("## What it says")).toBe(true)
    // Comments: the open pull request, else the one in the newest commit's subject (kept by sha).
    expect((await src.comments(pr)).comments.length).toBe(1)
    const base = notes.find((n) => n.id === "2026-11-18-lazy-checkouts")!
    expect(await src.prOf(base)).toBe(13172)
    const before = reads.length
    expect(await src.prOf(base)).toBe(13172)
    expect(reads.length).toBe(before)
    expect(await src.prOf(notes.find((n) => n.id === "2026-11-10-old-browser-post")!)).toBeNull()
    // The RFD list is unchanged by the notes' pull request.
    const { rfds } = await new Source(h, { repo: "manaflow-ai/cmuxterm-hq", dir: "docs/rfd", branch: "main" }).index()
    expect(rfds.map((r) => r.number).sort()).toEqual([0, 1, 2, 3, 4])
  })
})

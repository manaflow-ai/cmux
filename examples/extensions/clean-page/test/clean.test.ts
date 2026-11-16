import { describe, expect, test } from "bun:test"
import { buildPrompt, elements, hostOf, keepListed, originOf, parseReply, type Candidate } from "../src/clean.ts"

const c = (selector: string, extra: Partial<Candidate> = {}): Candidate => ({ selector, tag: "div", width: 300, height: 90, fixed: false, ...extra })
const candidates = [
  c("#ad-top", { label: "Advertisement" }),
  c("#cookie", { fixed: true, text: "We use cookies.   Accept all?" }),
  c("header.site", { tag: "header", fixed: true, width: 1280, height: 64 }),
  c("article.story", { tag: "article", text: "The real story" }),
  c("#content", { role: "main" })
]

describe("buildPrompt", () => {
  const prompt = buildPrompt({ url: "https://news.test/a", title: "A story", candidates })

  test("lists each element once with its selector, size and what it says", () => {
    expect(prompt).toContain('#ad-top | div | 300x90 | label="Advertisement"')
    expect(prompt).toContain('#cookie | div | 300x90 | fixed | text="We use cookies. Accept all?"')
    expect(prompt).toContain("header.site | header | 1280x64 | fixed")
    expect(prompt).toContain("Page: A story (https://news.test/a)")
    expect(prompt).toContain('{"hide": ["selector", ...], "unstick": ["selector", ...]}')
  })

  test("never offers the page's content", () => {
    expect(prompt).not.toContain("article.story")
    expect(prompt).not.toContain("#content")
  })

  test("cuts long text", () => {
    const long = buildPrompt({ url: "https://a.test", title: "", candidates: [c("#x", { text: "word ".repeat(100) })] })
    const line = long.split("\n").find((l) => l.startsWith("#x"))!
    expect(line.length).toBeLessThan(140)
    expect(long).toContain("Page: (untitled)")
  })
})

describe("parseReply", () => {
  test("reads bare JSON", () => {
    expect(parseReply('{"hide":["#ad-top"],"unstick":["header.site"]}')).toEqual({ hide: ["#ad-top"], unstick: ["header.site"] })
  })

  test("reads JSON in a code fence with prose around it", () => {
    const reply = 'Here you go:\n```json\n{ "hide": ["#ad-top", "#cookie"] }\n```\nThe header is fine.'
    expect(parseReply(reply)).toEqual({ hide: ["#ad-top", "#cookie"], unstick: [] })
  })

  test("skips braces in prose and objects without the lists", () => {
    const reply = 'I looked at {the page}. Context: {"note": "x"}. Answer: {"hide": ["a[title=\\"}\\"]"], "unstick": []}'
    expect(parseReply(reply)).toEqual({ hide: ['a[title="}"]'], unstick: [] })
  })

  test("drops entries that are not strings, and trims", () => {
    expect(parseReply('{"hide": [" #ad-top ", 3, null, ""], "unstick": "header"}')).toEqual({ hide: ["#ad-top"], unstick: [] })
  })

  test("null when there is nothing to read", () => {
    expect(parseReply("Sorry, I can't help with that.")).toBeNull()
    expect(parseReply('{"hide": [')).toBeNull()
    expect(parseReply("[1, 2]")).toBeNull()
  })
})

describe("keepListed", () => {
  test("keeps only listed selectors, each once", () => {
    const kept = keepListed({ hide: ["#ad-top", "#made-up", "#ad-top", "body"], unstick: ["header.site", "nav"] }, candidates)
    expect(kept).toEqual({ hide: ["#ad-top"], unstick: ["header.site"] })
  })

  test("never the article or main, even when the agent picks them", () => {
    expect(keepListed({ hide: ["article.story", "#content", "#cookie"], unstick: [] }, candidates)).toEqual({ hide: ["#cookie"], unstick: [] })
  })

  test("a selector picked for both is hidden", () => {
    expect(keepListed({ hide: ["header.site"], unstick: ["header.site"] }, candidates)).toEqual({ hide: ["header.site"], unstick: [] })
  })

  test("drops selectors cmux would refuse as rules", () => {
    const odd = [c("a[title='{x}']"), c("#a;b"), c("#ok"), c(`#${"x".repeat(300)}`), c("#tab\tbar"), c(`#${"é".repeat(127)}`), c(`#${"é".repeat(128)}`)]
    // 1 + 127 * 2 = 255 bytes fits; 1 + 128 * 2 = 257 does not.
    expect(keepListed({ hide: odd.map((o) => o.selector), unstick: [] }, odd)).toEqual({ hide: ["#ok", `#${"é".repeat(127)}`], unstick: [] })
  })

  test("at most 200 per list", () => {
    const many = Array.from({ length: 250 }, (_, i) => c(`#a${i}`))
    expect(keepListed({ hide: many.map((m) => m.selector), unstick: [] }, many).hide.length).toBe(200)
  })
})

test("originOf, hostOf and elements", () => {
  expect(originOf("https://News.Test:8443/a?b#c")).toBe("https://news.test:8443")
  expect(originOf("http://user:pw@a.test/")).toBe("http://a.test")
  expect(originOf("about:blank")).toBeNull()
  expect(originOf("file:///tmp/x.html")).toBeNull()
  expect(hostOf("https://www.news.test:8443")).toBe("www.news.test:8443")
  expect(hostOf("http://a.test/")).toBe("a.test")
  expect(elements(1)).toBe("1 element")
  expect(elements(3)).toBe("3 elements")
})

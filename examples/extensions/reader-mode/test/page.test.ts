// The reader page script (src/page.js) against a DOM: a news article with a menu, ads, a cookie
// popup, share buttons and lazy images becomes the title, byline and story text with its images;
// the second run takes the reader away and leaves the page as it was.
// Runs where the repository's web dependencies are installed (happy-dom from webviews/).
import { describe, expect, test } from "bun:test"
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"

const script = readFileSync(join(import.meta.dir, "../src/page.js"), "utf8")
const happyDom = join(import.meta.dir, "../../../../webviews/node_modules/happy-dom/lib/index.js")

const ARTICLE = `
<header class="site-header"><nav class="nav"><a href="/">Home</a><a href="/world">World</a><a href="/tech">Tech</a></nav></header>
<div class="cookie-banner">We use cookies. <button>Accept</button></div>
<div class="ad-slot"><a href="https://ads.example/x">Buy now</a></div>
<main>
  <article class="story">
    <h1>City opens its first all-night library</h1>
    <div class="byline">By Ana Ruiz</div>
    <div class="share-tools"><a href="#">Share</a><a href="#">Tweet</a></div>
    <div class="story-body">
      ${Array.from({ length: 8 }, (_, i) => `<p>Paragraph ${i + 1}: the library, which opened on Monday, keeps its doors open through the night, and readers, students and shift workers have already filled its tables, its study rooms and its quiet corners.</p>`).join("\n")}
      <div class="inline-promo"><a href="/subscribe">Subscribe today</a></div>
      <figure><img data-src="/images/library.jpg" src="data:image/gif;base64,R0lGOD" alt="The reading room"><figcaption>The reading room at 2 a.m.</figcaption></figure>
      <p>Officials said the late hours would continue through the winter, with more branches to follow if the pilot works, and that the cost was covered by the city's existing budget.</p>
    </div>
    <aside class="related"><a href="/a">Related one</a><a href="/b">Related two</a></aside>
  </article>
</main>
<footer class="footer"><a href="/about">About</a></footer>`

describe.skipIf(!existsSync(happyDom))("reader page script", () => {
  test("lays the article over the page, then takes it away", async () => {
    const { Window } = await import(happyDom)
    const window = new Window({ url: "https://news.example.com/2026/11/library" })
    window.document.title = "City opens its first all-night library | News"
    window.document.head.innerHTML = `<meta property="og:site_name" content="The Example News"><meta name="author" content="Ana Ruiz">`
    window.document.body.innerHTML = ARTICLE
    const run = () => new Function("document", "location", `return (${script})`)(window.document, window.location)

    const on = run()
    expect(on).toMatchObject({ reader: true, title: "City opens its first all-night library" })
    expect(on.words).toBeGreaterThan(200)
    const host = window.document.getElementById("cmux-reader-mode")!
    const shadow = host.shadowRoot!
    const body = shadow.querySelector(".body")!
    expect(shadow.querySelector(".site")!.textContent).toBe("The Example News")
    expect(shadow.querySelector(".meta")!.textContent).toBe("Ana Ruiz · 1 min read")
    expect(body.textContent).toContain("Paragraph 8")
    expect(body.textContent).toContain("existing budget")
    for (const junk of ["Accept", "Buy now", "Related one", "About", "Share", "World", "Subscribe today"]) expect(body.textContent).not.toContain(junk)
    expect(body.querySelector("img")!.getAttribute("src")).toBe("https://news.example.com/images/library.jpg")
    expect(body.querySelector("[class]")).toBeNull()
    expect(window.document.documentElement.style.overflow).toBe("hidden")

    expect(run()).toEqual({ reader: false })
    expect(window.document.getElementById("cmux-reader-mode")).toBeNull()
    expect(window.document.documentElement.style.overflow).toBe("")
    expect(window.document.querySelector(".cookie-banner")).not.toBeNull()
    await window.happyDOM.close()
  })

  // A body split into blocks, an ad slot between them and the lead image in a block of its own
  // (as large news sites draw a story), reads as one story with its image.
  test("a story split into blocks reads whole", async () => {
    const { Window } = await import(happyDom)
    const window = new Window({ url: "https://news.example.com/2026/11/split" })
    const para = (n: number) => `<p>Part ${n}: the council voted on Tuesday to keep the night buses running, and riders, drivers and shop owners all spoke at the meeting, which ran late into the evening.</p>`
    const block = (from: number) => `<div class="wrapper"><div class="spacer"><div data-component="text-block"><div class="rich">${[0, 1, 2].map((i) => para(from + i)).join("")}</div></div></div></div>`
    window.document.body.innerHTML = `
      <div class="ad-slot"><a href="https://ads.example/x">Buy now</a></div>
      <article><div class="stack">
        <div class="wrapper"><header><h1>Night buses stay</h1></header></div>
        <div class="wrapper"><figure><img src="/images/bus.jpg" alt="A night bus"></figure></div>
        <div class="wrapper"><div data-component="byline">By Sam Lee</div></div>
        ${block(1)}
        <div class="wrapper"><div class="ad-slot"><a href="https://ads.example/y">Ad</a></div></div>
        ${block(4)}
        <div class="wrapper"><div class="ad-slot"><a href="https://ads.example/z">Ad</a></div></div>
        ${block(7)}
      </div></article>`
    const on = new Function("document", "location", `return (${script})`)(window.document, window.location)
    expect(on).toMatchObject({ reader: true, title: "Night buses stay" })
    const shadow = window.document.getElementById("cmux-reader-mode")!.shadowRoot!
    const body = shadow.querySelector(".body")!
    for (const n of [1, 4, 7, 9]) expect(body.textContent).toContain(`Part ${n}:`)
    expect(body.querySelector("img")!.getAttribute("src")).toBe("https://news.example.com/images/bus.jpg")
    expect(shadow.querySelector(".meta")!.textContent).toStartWith("By Sam Lee")
    for (const junk of ["Buy now", "Ad", "By Sam Lee"]) expect(body.textContent).not.toContain(junk)
    await window.happyDOM.close()
  })

  test("a page with little text is not an article", () => {
    const { Window } = require(happyDom)
    const window = new Window({ url: "https://example.com/" })
    window.document.body.innerHTML = `<nav><a href="/a">A</a><a href="/b">B</a></nav><p>Sign in to continue.</p>`
    const result = new Function("document", "location", `return (${script})`)(window.document, window.location)
    expect(result).toEqual({ reader: false, reason: "no_article" })
    expect(window.document.getElementById("cmux-reader-mode")).toBeNull()
  })
})

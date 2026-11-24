// A New Tab view: it draws over cmux's own composer, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships).
// It shows once you pick it: `cmux settings set tabs.newTabApp local/{{NAME}}`. Save this file while
// `cmux ext dev` runs: cmux redraws the page. DESIGN.md says how a view should look; this page
// follows it: a title and where the tab starts, then cards of rows.
import { cmux, newTab, Panel, Row, Text, VStack } from "cmux-extension-sdk"

// A row's tap. Make it do the real thing: `cmux.actions.run("cmuxConfig.<name>")` runs an action
// from cmux-next.json once you turn on the actions:run scope in Settings > Apps.
const start = (what: string) => () =>
  cmux.toast({ title: what, message: "Make this row do it in src/main.ts.", tone: "success" })

// The export cmux-app.json names for cmux.newtab/1. `cwd` is the folder the new tab starts in.
export const renderNewTab = newTab(({ cwd }) => {
  const folder = cwd ? cwd.split("/").filter(Boolean).pop() : undefined
  return VStack({ spacing: 12 }, [
    Panel([
      Text("{{TITLE}}").font("largeTitle").weight("semibold"),
      Text(folder ? `Starting in ${folder}` : "A new tab").font("callout").color("secondary"),
    ]),
    Panel({ title: "Start" }, [
      VStack([
        Row({ title: "New agent chat", subtitle: "Ask Claude or Codex about this folder", symbol: "sparkles" }).onTap(start("New agent chat")),
        Row({ title: "New terminal", subtitle: cwd ?? "Your home folder", symbol: "terminal" }).onTap(start("New terminal")),
        Row({ title: "Open a file", subtitle: "Markdown, code or a picture", symbol: "doc.text" }).onTap(start("Open a file")),
      ]),
    ]),
  ])
})

// A whole New Tab page, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships).
// It shows once you pick it: `cmux settings set tabs.newTabApp local/{{NAME}}`. Save this file while
// `cmux ext dev` runs: cmux redraws the page.
import { Button, cmux, newTab, Panel, Text, VStack } from "cmux-extension-sdk"

// The export cmux-app.json names for cmux.newtab/1. `cwd` is the folder the new tab starts in.
export const renderNewTab = newTab(({ cwd }) =>
  VStack([
    Panel({ title: "Hello from {{TITLE}}" }, [
      Text(cwd ? `Starting in ${cwd}` : "A new tab"),
      Button("Say hi", () => cmux.toast({ title: "Hi from my New Tab page", tone: "success" })),
    ]),
  ])
)

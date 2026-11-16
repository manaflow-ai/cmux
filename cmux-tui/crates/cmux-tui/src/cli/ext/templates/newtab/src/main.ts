// A whole New Tab page, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships).
// It shows once you pick it: `cmux settings set tabs.newTabApp local/{{NAME}}`. Save this file while
// `cmux ext dev` runs: cmux redraws the page.
//
// The sandbox is not a browser: there is no setInterval, setTimeout or Intl. Tick with
// cmux.timer.every(ms, fn) (and cmux.timer.clear(id) in onCleanup), and format dates by hand.
// A render that throws, or a page with nothing visible on it, does not leave a blank tab: cmux
// draws its own New Tab page with a note that names this extension and the error.
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

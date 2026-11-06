// The customize app's script: a classic script, not a module (no import or export).
// The scene globals (VStack, Panel, Row, Button, Toggle, Text, signal, computed, cmux, ...)
// are already defined. cmux reloads this file every time it is saved.

// State lives in signals; a view that reads one redraws when it changes.
const [count, setCount] = signal(0)

// One render function per implementation in cmux-app.json (its "export").
function renderSection() {
  return VStack([
    Panel({ title: "Hello" }, [
      Text(() => `Clicked ${count()} times`).font("headline"),
      HStack([
        Button("Click", () => setCount((n) => n + 1)),
        Spacer(),
        Button("Say hi", () => cmux.toast({ title: "Hi from my section", tone: "success" }))
      ])
    ]),
    Row({ title: "Edit ~/.config/cmux/customize/main.js", symbol: "pencil", tint: cmux.theme.text.secondary })
  ])
}

// Hand every render function to cmux, once, in one object.
globalThis.__cmuxAppExports = { renderSection }

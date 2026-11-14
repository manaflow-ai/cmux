/// <reference path="../cmux-app.d.ts" />
// A sidebar section. Save this file while `cmux ext dev` runs: it rebuilds
// dist/main.js and cmux redraws the section. The scene globals (VStack, Panel,
// Button, Text, signal, cmux, ...) are defined by cmux; cmux-app.d.ts types them.

// State lives in signals; a view that reads one redraws when it changes.
const [count, setCount] = signal(0)

// The export cmux-app.json names for cmux.section/1.
export function renderSection() {
  return VStack([
    Panel({ title: "Hello" }, [
      Text(() => `Clicked ${count()} times`),
      HStack([
        Button("Click", () => setCount((n) => n + 1)),
        Spacer(),
        Button("Say hi", () => cmux.toast({ title: "Hi from my extension", tone: "success" })),
      ]),
    ]),
  ])
}

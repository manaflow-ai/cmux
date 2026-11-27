// A sidebar section, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships).
// Save this file while `cmux ext dev` runs: it rebuilds dist/main.js and cmux redraws the section.
import { Button, cmux, HStack, Panel, section, signal, Spacer, Text, VStack } from "cmux-extension-sdk"

// State lives in signals; a view that reads one redraws when it changes.
const [count, setCount] = signal(0)

// The export cmux-app.json names for cmux.section/1.
export const renderSection = section(() =>
  VStack([
    Panel({ title: "Hello" }, [
      Text(() => `Clicked ${count()} times`),
      HStack([
        Button("Click", () => setCount((n) => n + 1)),
        Spacer(),
        Button("Say hi", () => cmux.toast({ title: "Hi from my extension", tone: "success" })),
      ]),
    ]),
  ])
)

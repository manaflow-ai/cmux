// A command, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships).
// catalog.json declares it: it runs from the command palette, as `cmux {{NAME}} hello`, and as a
// tool for agents. Save this file while `cmux ext dev` runs: the next run uses the new code.
import { command } from "cmux-extension-sdk"

// The export catalog.json names for the op {{NS}}.hello.
export const hello = command(async (args: { name?: string }, { cmux }) => {
  const greeting = `Hello, ${args.name ?? "you"}`
  await cmux.toast({ title: greeting, tone: "success" })
  return { greeting }
})

/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Standup: a command-only app. No scene, no pane: three catalog ops that the
// palette, `cmux apps run manaflow-ai/standup <add|list|clear>` and MCP all reach.

interface Note { at: string; text: string }

const KEY = "notes"

async function notes(): Promise<Note[]> {
  return ((await cmux.storage.get<Note[]>(KEY)) ?? []).filter((n) => typeof n?.text === "string")
}

export async function add(args: { text?: string } = {}) {
  const text = String(args.text ?? "").trim()
  if (!text) throw new Error("text is empty")
  const next = [...(await notes()), { at: new Date().toISOString(), text }]
  await cmux.storage.set(KEY, next)
  return { count: next.length }
}

export async function list() {
  const all = await notes()
  return { count: all.length, notes: all }
}

export async function clear() {
  const count = (await notes()).length
  await cmux.storage.delete(KEY)
  return { cleared: count }
}

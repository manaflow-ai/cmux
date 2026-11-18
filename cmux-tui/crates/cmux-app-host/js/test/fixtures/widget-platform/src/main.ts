// Test-only widget for widgets.test.ts: the least a widget does on the platform. A cmux.section/1
// card whose size setting picks how many events it shows (1, 3, 5) and whose menu switches size;
// events come from cmux.system_calendar.events, which never prompts; a button's tap asks with
// cmux.system_calendar.request_access. The sample widgets live in the sample widget repos
// (manaflow-ai/cmux-widget-*).
import { Button, cmux, computed, ForEach, Menu, Panel, signal, Text, VStack, type CalendarAccess, type CalendarEvent, type View } from "cmux-extension-sdk"

type Size = "small" | "medium" | "large"
const SHOWN: Record<Size, number> = { small: 1, medium: 3, large: 5 }
const sizeOf = (s: unknown): Size => (s === "medium" || s === "large" ? s : "small")

const [events, setEvents] = signal<CalendarEvent[]>([])
const [access, setAccess] = signal<CalendarAccess | null>(null)

async function load() {
  const answer = await cmux.system_calendar.events({ days: 7, limit: 5 })
  setAccess(answer.access)
  setEvents(answer.events)
}

async function ask() {
  const answer = await cmux.system_calendar.request_access({})
  setAccess(answer.access)
  if (answer.access === "granted") await load()
}

export function renderWidget(): View {
  void load()
  const size = computed(() => sizeOf(cmux.app.settings().size))
  const shown = computed(() => events().filter((e) => e.end > Date.now()).slice(0, SHOWN[size()]))
  const pick = (s: Size, title: string) => Button(size() === s ? `✓ ${title}` : title, () => void cmux.app.settings.set({ size: s }))
  return Panel({ style: "card", spacing: 8 }, [
    Text(() => size().toUpperCase()).font("caption").color(cmux.theme.accent),
    () =>
      access() === "notDetermined"
        ? Button("Show my calendar", ask)
        : VStack({ spacing: 4, alignment: "leading" }, [ForEach({ items: shown, key: (e) => e.id }, (e) => Text(() => e().title).lineLimit(1))])
  ]).contextMenu(() => [Menu("Size", [pick("small", "Small"), pick("medium", "Medium"), pick("large", "Large")])])
}

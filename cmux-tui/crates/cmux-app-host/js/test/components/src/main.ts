// The finished components the gallery draws (RFD 0009 slice 4): Stat and Chart, every variant,
// and the loading, error and empty states, built only on cmux-extension-sdk.
// components.test.ts packs it, checks the scenes and records them for
// webviews/src/apps/scene/Components.gallery.tsx.
import {
  Badge,
  Button,
  Caption,
  Chart,
  Gauge,
  HStack,
  ProgressView,
  Row,
  RowList,
  SPACE,
  Stat,
  TextIn,
  VStack,
  signal,
  type ComponentState,
  type ComponentVariant,
} from "../../../../../cmux-extension-sdk/typescript/src/index.ts"

const VARIANTS: ComponentVariant[] = ["standard", "prominent", "subtle"]
const STATES: ComponentState[] = ["loading", "error", "empty"]
const week = [12, 18, 9, 22, 30, 26, 34]

export function renderStats() {
  return VStack({ spacing: SPACE.l, alignment: "leading" }, [
    HStack({ spacing: SPACE.xxl }, [
      Stat("1,284", { label: "Requests", delta: "+12%", trend: "up" }),
      Stat("212 ms", { label: "Latency", delta: "+8%", trend: "up", goodTrend: "down" }),
      Stat("99.9%", { label: "Uptime", delta: "0%", trend: "flat" }),
    ]),
    HStack({ spacing: SPACE.xxl }, VARIANTS.map((v) => Stat(42, { label: v }).variant(v))),
  ])
}

export function renderCharts() {
  return VStack({ spacing: SPACE.m, alignment: "leading" }, [
    TextIn("label", "Line"),
    Chart(week),
    TextIn("label", "Bar"),
    Chart(week, { kind: "bar" }),
    TextIn("label", "Below zero"),
    Chart([4, -2, -6, 3, 8, -1], { kind: "bar", color: "warning" }),
    TextIn("label", "Variants"),
    HStack({ spacing: SPACE.m }, VARIANTS.map((v) => Chart(week).variant(v).frame({ width: 96 }))),
  ])
}

export function renderVariants() {
  return VStack({ spacing: SPACE.m, alignment: "leading" }, [
    HStack({ spacing: SPACE.s }, VARIANTS.map((v) => Badge(v, "accent").variant(v))),
    HStack({ spacing: SPACE.s }, VARIANTS.map((v) => Button(v).variant(v))),
    ...VARIANTS.map((v) => Row({ title: `Row, ${v}`, subtitle: "a detail", symbol: "star" }).variant(v)),
    ...VARIANTS.map((v) => ProgressView(0.6).variant(v)),
  ])
}

export function renderStates() {
  return VStack({ spacing: SPACE.l, alignment: "leading" }, [
    ...STATES.map((s) =>
      HStack({ spacing: SPACE.xxl }, [
        Stat("—", { label: "Requests" }).state(s),
        Chart([]).state(s, s === "error" ? "Could not load" : null).frame({ width: 120 }),
      ])
    ),
    Row({ title: "Build", subtitle: "main" }).state("loading", "Fetching checks"),
    Button("Deploy").state("error", "Offline"),
    Gauge(0.4, { label: "Battery", state: "empty" }),
  ])
}

// A list whose state the test moves: loading, then rows, then error.
const [state, setState] = signal<ComponentState | null>("loading")
;(globalThis as { setListState?: (s: ComponentState | null) => void }).setListState = setState

export function renderList() {
  return VStack({ spacing: SPACE.s, alignment: "leading" }, [
    Caption("Today"),
    RowList(() => [
      { id: "a", title: "Standup", detail: "9:30" },
      { id: "b", title: "Review", detail: "14:00" },
    ], { state, stateMessage: () => (state() === "error" ? "Calendar is offline" : null) }),
  ])
}

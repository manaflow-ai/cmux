// The scene `cmux ext design --show --scene` draws (Settings > Design system): the SDK's
// DesignSystemView of the person's resolved system, with the roles cmux changed since their
// design.json recorded its base. The CLI runs it in the app runtime (QuickJS, as the daemon's app
// host does) and mounts `renderDesign` with the resolved system in the context; the layering,
// the base and the changes are Rust's (design_layers.rs). dist/main.js is its packed build,
// embedded in the CLI: `bun cmux-tui/crates/cmux-app-host/tools/pack.ts <this folder>` rebuilds it
// and design.test.ts fails when it is stale.
import { defineDesign, DesignSystemView, pane, type DesignChange, type DesignSpec } from "cmux-extension-sdk"

type Shown = { system?: DesignSpec; changed?: DesignChange[]; note?: string }

export const renderDesign = pane((context) => {
  const shown = ((context as { design?: Shown }).design ?? {}) as Shown
  const system = defineDesign(shown.system ?? { design: "cmux.design/1" })
  return DesignSystemView(system, { note: shown.note, changed: shown.changed ?? [] })
})

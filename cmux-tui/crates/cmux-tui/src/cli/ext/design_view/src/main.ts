// The scene `cmux ext design --show --scene` draws (Settings > Design system): the SDK's
// DesignSystemView of the person's resolved system, with the roles cmux changed since their
// design.json recorded its base. The CLI runs it in the app runtime (QuickJS, as the daemon's app
// host does) and mounts `renderDesign` with the resolved system in the context; the layering,
// the base and the changes are Rust's (design_layers.rs). cmux-tui's build.rs packs it with
// cmux-app-host/tools/pack.ts into $OUT_DIR and the CLI embeds that; nothing packed is committed.
import { defineDesign, DesignSystemView, pane, type DesignChange, type DesignSpec } from "cmux-extension-sdk"

type Shown = { system?: DesignSpec; changed?: DesignChange[]; note?: string }

export const renderDesign = pane((context) => {
  const shown = ((context as { design?: Shown }).design ?? {}) as Shown
  const system = defineDesign(shown.system ?? { design: "cmux.design/1" })
  return DesignSystemView(system, { note: shown.note, changed: shown.changed ?? [] })
})

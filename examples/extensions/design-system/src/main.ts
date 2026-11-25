// Design system: a system of its own on top of cmux's, and a pane that shows it. cmux-design.json
// (`cmux.design/1`) overrides two type roles, adds one, replaces the spacing scale and names two
// colors; everything else is cmux's. It imports nothing but the public SDK.
// - defineDesign(spec) merges the file over cmux's system and throws, naming the field and the
//   fix, on an entry that does not hold. `cmux ext dev` checks the pane against the same file.
// - DesignSystemView(system) draws a system with itself: its type, spacing, colors, components
//   and limits. The two buttons flip between cmux's and this one.

import { Button, cmuxDesign, defineDesign, DesignSystemView, HStack, pane, signal, Spacer, VStack, type View } from "cmux-extension-sdk"
import spec from "../cmux-design.json" with { type: "json" }

export const design = defineDesign(spec)

type Shown = "cmux" | "yours"
const [shown, setShown] = signal<Shown>("yours")

/** The pane: which system to show, then the system. */
export const renderDesign = pane((): View =>
  VStack({ spacing: 0, alignment: "leading" }, [
    HStack({ spacing: 8 }, [
      Button("cmux", () => setShown("cmux")).disabled(() => shown() === "cmux"),
      Button("Yours", () => setShown("yours")).disabled(() => shown() === "yours"),
      Spacer(),
    ]).padding(16),
    () => DesignSystemView(shown() === "cmux" ? cmuxDesign : design),
  ])
)

// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Tabs, TabsContent, TabsList, TabsTrigger, type TabsVariant } from "./Tabs";

type Props = { variant?: TabsVariant; initial?: string };

const TABS = [
  { value: "general", label: "General" },
  { value: "models", label: "Models" },
  { value: "keys", label: "Keys" },
  { value: "archived", label: "Archived", disabled: true },
];

function TabsGallery({ variant = "pill", initial = "general" }: Props) {
  const [value, setValue] = useState(initial);
  return (
    <div className="ui-controls-stage">
      <Tabs variant={variant} value={value} onValueChange={(next) => setValue(String(next))}>
        <TabsList aria-label="Settings sections">
          {TABS.map((tab) => (
            <TabsTrigger key={tab.value} value={tab.value} disabled={tab.disabled}>
              {tab.label}
            </TabsTrigger>
          ))}
        </TabsList>
        {TABS.map((tab) => (
          <TabsContent key={tab.value} value={tab.value}>
            {tab.label} settings
          </TabsContent>
        ))}
      </Tabs>
      <output className="ui-controls-receipt" data-testid="tabs-receipt">
        {value}
      </output>
    </div>
  );
}

const arrows: Play = async (ctx) => {
  await ctx.focus({ role: "tab", name: "General" });
  await ctx.press("ArrowRight");
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.find({ testId: "tabs-receipt" }).textContent === "models");
};

export default componentEntry<Props>({
  id: "ui.tabs",
  title: "Tabs",
  area: "UI primitives",
  height: 220,
  covers: ["ui/Tabs.tsx"],
  load: async () => TabsGallery,
  styles: () => Promise.all([import("./ui.css"), import("./controls.gallery.css")]),
  variants: {
    pill: { props: { variant: "pill" }, note: "The default: the selection fill on the active tab, like our rows." },
    underline: { props: { variant: "underline" }, note: "Page-level sections over a hairline." },
    segmented: { props: { variant: "segmented" }, note: "Two to four peer modes, as Claude's settings do." },
    "segmented-second": { props: { variant: "segmented", initial: "models" } },
    arrows: { props: {}, play: arrows },
  },
});

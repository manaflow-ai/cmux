// Tabs over Base UI Tabs (roles tablist, tab and tabpanel; arrows move between tabs, Home and End,
// direction-aware), in shadcn's shape: Tabs, TabsList, TabsTrigger, TabsContent. Drawn with the
// design scale (ui/controls.css). The active tab is marked on the tab itself (no measured indicator),
// so nothing moves after the first frame; the active fill covers that tab only.
import { createContext, useContext, type ComponentProps } from "react";
import { Tabs as BaseTabs } from "@base-ui/react/tabs";
import { cx } from "./cx";

/** pill: a soft fill on the active tab. underline: a 2 px bar under it. segmented: a track holding
 * the tabs, the active one raised. */
export type TabsVariant = "pill" | "underline" | "segmented";

/** Our parts take a plain class name (Base UI also takes a function of state). */
type Classed<T> = Omit<T, "className"> & { className?: string };

const VariantContext = createContext<TabsVariant>("pill");

export interface TabsProps extends Classed<ComponentProps<typeof BaseTabs.Root>> {
  variant?: TabsVariant;
}

export function Tabs({ variant = "pill", className, ...rest }: TabsProps) {
  return (
    <VariantContext value={variant}>
      <BaseTabs.Root className={cx("ui-tabs", className)} data-variant={variant} {...rest} />
    </VariantContext>
  );
}

export function TabsList({ className, ...rest }: Classed<ComponentProps<typeof BaseTabs.List>>) {
  const variant = useContext(VariantContext);
  return <BaseTabs.List className={cx("ui-tabs-list", className)} data-variant={variant} {...rest} />;
}

export function TabsTrigger({ className, ...rest }: Classed<ComponentProps<typeof BaseTabs.Tab>>) {
  return <BaseTabs.Tab className={cx("ui-button ui-tabs-trigger", className)} {...rest} />;
}

export function TabsContent({ className, ...rest }: Classed<ComponentProps<typeof BaseTabs.Panel>>) {
  return <BaseTabs.Panel className={cx("ui-tabs-content", className)} {...rest} />;
}

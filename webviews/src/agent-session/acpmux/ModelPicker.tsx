import { useCallback, useLayoutEffect, useRef, useState } from "react";
import { buildTaxonomy } from "./modelTaxonomy";
import { menuRoom, pickerLayout, type MenuHandle, type ModelPickerProps, type PickerLayout } from "./modelPickerLayout";
import { ModelPickerCascade } from "./ModelPickerCascade";
import { ModelPickerDrill } from "./ModelPickerDrill";
import { ModelPickerShell } from "./ModelPickerShell";

/// The composer's model picker. Each opening draws the cascade, whose submenus open beside
/// their rows, when the pane has room for them left of the menu; in a narrow pane it draws the
/// in-place drill instead, recents first. The choice is made once per opening: the menu's first
/// frame is measured (`measureRoom`, else its left edge) before any rows show.
export function ModelPicker(props: ModelPickerProps) {
  const [open, setOpen] = useState(false);
  const [layout, setLayout] = useState<PickerLayout | undefined>(undefined);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const handle = useRef<MenuHandle | undefined>(undefined);
  const openChange = useCallback((next: boolean) => {
    setOpen(next);
    setLayout(undefined);
  }, []);
  const close = useCallback(() => openChange(false), [openChange]);
  const { catalog, harness, measureRoom = menuRoom } = props;
  useLayoutEffect(() => {
    if (!open || layout || !menu.current) return;
    const entry = catalog.find((candidate) => candidate.id === harness);
    // Providers, then families, then models: two submenus side by side; one otherwise.
    const depth = buildTaxonomy(entry?.models ?? [], entry?.name ?? harness ?? "").providers.length > 1 ? 2 : 1;
    setLayout(pickerLayout(measureRoom(menu.current), depth));
  }, [open, layout, catalog, harness, measureRoom]);
  const Body = layout === "drill" ? ModelPickerDrill : ModelPickerCascade;
  return (
    <ModelPickerShell
      layout={layout}
      chip={props.label}
      open={open}
      onOpenChange={openChange}
      onKeyDown={(event) => handle.current?.keyDown(event)}
      onPointerMove={(event) => handle.current?.track(event)}
      trigger={trigger}
      menu={menu}
    >
      {layout && <Body {...props} trigger={trigger} menu={menu} handle={handle} close={close} />}
    </ModelPickerShell>
  );
}

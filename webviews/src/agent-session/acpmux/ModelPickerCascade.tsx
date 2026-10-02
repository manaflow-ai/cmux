import type React from "react";
import { useId, useState } from "react";
import { SearchIcon } from "./ComposerPickers";
import { t } from "./i18n";
import { MenuLevel, rowId } from "./MenuLevel";
import { menuNodes, pickerData, recentKey, typeKey } from "./modelMenuNodes";
import { useMenuHandle, type ModelMenuProps } from "./modelPickerLayout";
import { useMenuTree, type MenuNode } from "./useMenuTree";

/// The model menu in a pane with room beside it: a compact menu that grows up from the chip.
/// Nearest the chip are the numbered recents (1 at the bottom), then the reasoning row and the
/// current family's other models, then one row per provider (or, for a single-provider harness,
/// per family) and the harness. Those rows open their submenu beside them on hover, best row at
/// the bottom next to the pointer, the rest under "More…"; a click on one lands on its default
/// in one action.
export function ModelPickerCascade(props: ModelMenuProps) {
  const { trigger, menu, close } = props;
  const [query, setQuery] = useState("");
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const idPrefix = `mp${useId().replace(/[^\w]/g, "")}`;
  const data = pickerData(props);
  const build = menuNodes(data, props, {
    order: "bestLast",
    expanded,
    expand: (key) => setExpanded((keys) => new Set([...keys, key])),
  });
  const some = (node: MenuNode | undefined) => (node ? [node] : []);
  const root: MenuNode[] = query
    ? build.matches(query)
    : [
        ...some(build.harnessRow()),
        ...build.upperLayer(),
        ...build.currentFamily(),
        ...some(build.effortRow(() => trigger.current?.focus())),
        ...build.recentRows(),
      ];
  const tree = useMenuTree(root, {
    entry: "last",
    onDone: close,
    aim: (level) => menu.current?.querySelector(`[data-mp-sub="${level}"]`),
  });
  const filter = (next: string) => {
    setQuery(next);
    tree.reset();
  };
  const keyDown = (event: React.KeyboardEvent) => {
    if (event.key === "Escape") event.stopPropagation();
    const recent = recentKey(event, query);
    if (recent !== undefined) {
      const combo = data.numbered[recent];
      if (combo) {
        data.landCombo(combo);
        close();
      }
      return;
    }
    if (tree.keyDown(event)) return;
    if (event.key === "Escape") {
      event.preventDefault();
      if (query) filter("");
      else close();
    } else if (event.key === "Tab") close();
    else typeKey(event, query, filter);
  };
  const active = tree.activeKey(tree.level);
  useMenuHandle(props, { keyDown, track: (event) => tree.track(event) }, active && rowId(idPrefix, tree.level, active));
  return (
    <>
      <div className={`acpmux-menu-search${query ? "" : " acpmux-menu-search-empty"}`} aria-live="polite">
        <SearchIcon />
        <span>{query || t("picker.search")}</span>
      </div>
      <MenuLevel nodes={root} level={0} tree={tree} idPrefix={idPrefix} />
    </>
  );
}

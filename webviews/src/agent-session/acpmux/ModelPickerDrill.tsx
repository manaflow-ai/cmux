import type React from "react";
import { useId, useLayoutEffect, useState } from "react";
import { SearchIcon } from "./ComposerPickers";
import { t } from "./i18n";
import { MenuLevel, rowId } from "./MenuLevel";
import { menuNodes, pickerData, recentKey, typeKey } from "./modelMenuNodes";
import type { TaxModel } from "./modelTaxonomy";
import { useMenuHandle, type ModelMenuProps } from "./modelPickerLayout";
import { useMenuTree, type MenuNode } from "./useMenuTree";

/// The model menu in a pane too narrow for submenus beside it: a short list that grows up from
/// the chip, recents first. Nearest the chip are the
/// numbered recents (1 at the bottom), then the current family's other models, the reasoning row,
/// and one "More models" row. That row drills in place, without leaving the popover, to the
/// harness's providers (or families) under a breadcrumb, Harness › Provider › Family; hovering a
/// row there opens its next layer right above it, best row next to it, so the row under the
/// pointer stays put as the menu grows up from the chip. Typing filters the level shown.
export function ModelPickerDrill(props: ModelMenuProps) {
  const { trigger, menu, close } = props;
  const [browsing, setBrowsing] = useState(false);
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
  const home: MenuNode[] = [
    {
      key: "browse",
      label: t("picker.moreModels"),
      detail: data.harnessName,
      run: () => {
        setBrowsing(true);
        setQuery("");
        tree.reset();
        return "keep";
      },
    },
    ...some(build.effortRow(() => trigger.current?.focus())),
    ...build.currentFamily(),
    ...build.recentRows(),
  ];
  const harnessRows: MenuNode[] =
    data.harnesses.length > 1
      ? data.harnesses.map((harness) => ({
          key: `harness:${harness.id}`,
          label: harness.name,
          detail: harness.id === props.harness ? undefined : t("picker.newChat"),
          section: t("picker.harness"),
          checked: harness.id === props.harness,
          run: () => {
            if (harness.id !== props.harness) props.onHarness?.(harness.id);
          },
        }))
      : [];
  const browse: MenuNode[] = [...harnessRows, ...build.upperLayer()];
  // The breadcrumb follows the rows opened under the harness; a query filters what they hold.
  const rootNodes = browsing ? browse : home;
  const tree = useMenuTree(rootNodes, {
    entry: "last",
    onDone: close,
    aim: (level) => menu.current?.querySelector(`[data-mp-sub="${level}"]`),
  });
  const crumbs: { label: string; models: TaxModel[] }[] = [];
  if (browsing)
    for (let at = 0; at < tree.path.length; at += 1) {
      const key = tree.path[at]!;
      const label = tree.nodesAt(at).find((node) => node.key === key)?.label;
      const provider = data.taxonomy.providers.find((candidate) => `provider:${candidate.name}` === key);
      const family = data.taxonomy.providers
        .flatMap((candidate) => candidate.families)
        .find((candidate) => `family:${candidate.key}` === key);
      const models = provider?.models ?? family?.models;
      if (label && models) crumbs.push({ label, models });
    }
  const scope = crumbs.at(-1)?.models;
  const root: MenuNode[] = query ? build.matches(query, browsing ? scope : undefined) : rootNodes;
  const filtered = useMenuTree(query ? root : [], {
    entry: "last",
    onDone: close,
    aim: () => undefined,
  });
  const shown = query ? filtered : tree;

  const filter = (next: string) => {
    setQuery(next);
    filtered.reset();
  };
  const back = () => {
    setBrowsing(false);
    setQuery("");
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
    if (shown.keyDown(event)) return;
    if (event.key === "Escape") {
      event.preventDefault();
      if (query) filter("");
      else if (browsing) back();
      else close();
    } else if (event.key === "Backspace" && !query && browsing) {
      event.preventDefault();
      back();
    } else if (event.key === "Tab") close();
    else typeKey(event, query, filter);
  };
  // The best rows are at the bottom, next to the chip: a tall level opens scrolled down to them.
  useLayoutEffect(() => {
    if (menu.current) menu.current.scrollTop = menu.current.scrollHeight;
  }, [menu, browsing, query]);
  const active = shown.activeKey(shown.level);
  useMenuHandle(
    props,
    { keyDown, track: (event) => shown.track(event) },
    active && rowId(idPrefix, shown.level, active),
  );
  return (
    <>
      {browsing && (
        <nav className="acpmux-mp-crumbs" aria-label={t("picker.allModels")}>
          <button
            type="button"
            tabIndex={-1}
            className="acpmux-mp-crumb acpmux-mp-back"
            aria-label={t("picker.back")}
            onMouseDown={(event) => {
              event.preventDefault();
              back();
            }}
          >
            ‹
          </button>
          <button
            type="button"
            tabIndex={-1}
            className="acpmux-mp-crumb"
            onMouseDown={(event) => {
              event.preventDefault();
              tree.collapse(0);
            }}
          >
            {data.harnessName}
          </button>
          {crumbs.map((crumb, index) => (
            <span key={crumb.label} className="acpmux-mp-crumb-step">
              <span aria-hidden="true">›</span>
              <button
                type="button"
                tabIndex={-1}
                className="acpmux-mp-crumb"
                aria-current={index === crumbs.length - 1 ? "location" : undefined}
                onMouseDown={(event) => {
                  event.preventDefault();
                  tree.collapse(index + 1);
                }}
              >
                {crumb.label}
              </button>
            </span>
          ))}
        </nav>
      )}
      <div className={`acpmux-menu-search${query ? "" : " acpmux-menu-search-empty"}`} aria-live="polite">
        <SearchIcon />
        <span>{query || t("picker.search")}</span>
      </div>
      <MenuLevel nodes={root} level={0} tree={shown} idPrefix={idPrefix} subAbove />
    </>
  );
}

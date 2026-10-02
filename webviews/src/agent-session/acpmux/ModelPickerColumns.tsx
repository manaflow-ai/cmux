import type React from "react";
import { useId, useRef, useState } from "react";
import { SearchIcon } from "./ComposerPickers";
import { EffortTrack } from "./EffortTrack";
import { t } from "./i18n";
import { MenuRow } from "./MenuRow";
import { rowId } from "./MenuLevel";
import { folded, pickerData, recentKey, typeKey } from "./modelMenuNodes";
import {
  effortFor,
  familyDefault,
  landOnFamily,
  landOnModel,
  landOnProvider,
  providerDefault,
  type Landing,
  type TaxModel,
} from "./modelTaxonomy";
import type { ModelPickerProps } from "./modelPickerVariant";
import { ModelPickerShell } from "./ModelPickerShell";
import { useHoverIntent } from "./useHoverIntent";
import type { MenuNode } from "./useMenuTree";

type ColumnId = "harness" | "provider" | "family" | "model" | "filter";
type Column = { id: ColumnId; title: string; nodes: MenuNode[]; selected?: string };

/// Variant B, "columns": one wider popover laid out like Photoshop's panels, provider | family |
/// model (a harness column first when the catalog has several, and no provider column for a
/// single-provider harness). Each column lists its best row at the bottom, the rest under
/// "More…"; hovering a provider or family previews its next column, a click on any row lands
/// on its default. Under the columns sit the reasoning slider for the highlighted model and,
/// along the bottom edge nearest the chip, the numbered recents.
export function ModelPickerColumns(props: ModelPickerProps) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const [preview, setPreview] = useState<{ provider?: string; family?: string }>({});
  const [focus, setFocus] = useState<ColumnId>("model");
  const [active, setActive] = useState<Partial<Record<ColumnId, string>>>({});
  // An effort set on the slider for a model the session doesn't run yet; the next landing carries it.
  const [staged, setStaged] = useState<string | undefined>(undefined);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const idPrefix = `mp${useId().replace(/[^\w]/g, "")}`;
  const intent = useHoverIntent();
  const data = pickerData(props);
  const expand = (key: string) => setExpanded((keys) => new Set([...keys, key]));

  const land = (landing: Landing | undefined) => {
    if (landing) props.onLand(landing.model, staged ?? landing.effort);
  };
  const providers = data.rankProviders(data.taxonomy.providers);
  const provider = providers.find((candidate) => candidate.name === preview.provider) ?? data.provider ?? providers[0];
  const providerModel = provider && providerDefault(provider, data.recents, data.current);
  const families = provider ? data.rankFamilies(provider.families) : [];
  const family =
    families.find((candidate) => candidate.key === preview.family) ??
    families.find((candidate) => candidate.name === providerModel?.family) ??
    families[0];
  const familyModel = family && familyDefault(family, data.recents, data.current);
  const modelRow = (model: TaxModel, detail?: string): MenuNode => ({
    key: `model:${model.id}`,
    label: model.name,
    detail,
    checked: model.id === props.model,
    run: () => land(landOnModel(model, data.recents, data.current)),
  });

  const columns: Column[] = [];
  if (query) {
    const found = data.filter(query);
    columns.push({
      id: "filter",
      title: t("picker.model"),
      nodes: found.length
        ? found.map((model) => modelRow(model, `${model.provider} · ${model.family}`)).reverse()
        : [{ key: "none", label: t("picker.noMatches") }],
    });
  } else {
    if (data.harnesses.length > 1)
      columns.push({
        id: "harness",
        title: t("picker.harness"),
        nodes: data.harnesses.map((harness) => ({
          key: `harness:${harness.id}`,
          label: harness.name,
          detail: harness.id === props.harness ? undefined : t("picker.newChat"),
          checked: harness.id === props.harness,
          run: () => {
            if (harness.id !== props.harness) props.onHarness?.(harness.id);
          },
        })),
        selected: `harness:${props.harness}`,
      });
    if (providers.length > 1)
      columns.push({
        id: "provider",
        title: t("picker.provider"),
        nodes: folded(
          "providers",
          providers,
          (candidate) => ({
            key: `provider:${candidate.name}`,
            label: candidate.name,
            detail: providerDefault(candidate, data.recents, data.current)?.name,
            run: () => land(landOnProvider(candidate, data.recents, data.current)),
          }),
          "bestLast",
          expanded,
          expand,
        ),
        selected: provider && `provider:${provider.name}`,
      });
    columns.push({
      id: "family",
      title: t("picker.family"),
      nodes: folded(
        `families:${provider?.name}`,
        families,
        (candidate) => ({
          key: `family:${candidate.key}`,
          label: candidate.name,
          detail: familyDefault(candidate, data.recents, data.current)?.name,
          run: () => land(landOnFamily(candidate, data.recents, data.current)),
        }),
        "bestLast",
        expanded,
        expand,
      ),
      selected: family && `family:${family.key}`,
    });
    columns.push({
      id: "model",
      title: t("picker.model"),
      nodes: family
        ? folded(
            `family:${family.key}`,
            data.rankModels(family.models),
            (model) => modelRow(model),
            "bestLast",
            expanded,
            expand,
          )
        : [],
    });
  }
  const column = columns.find((candidate) => candidate.id === focus) ?? columns.at(-1)!;
  const activeIn = (target: Column): string | undefined => {
    const key = active[target.id];
    if (key && target.nodes.some((node) => node.key === key)) return key;
    if (target.selected && target.nodes.some((node) => node.key === target.selected)) return target.selected;
    const checked = [...target.nodes].reverse().find((node) => node.checked);
    if (checked) return checked.key;
    if (target.id === "model" && familyModel) return `model:${familyModel.id}`;
    return target.nodes.at(-1)?.key;
  };
  // The slider follows the model the pointer or the arrows rest on.
  const modelColumn = columns.find((candidate) => candidate.id === "model" || candidate.id === "filter");
  const activeModelKey = modelColumn && activeIn(modelColumn);
  const activeModel = data.taxonomy.byId.get(activeModelKey?.replace(/^model:/, "") ?? "") ?? data.model;
  const sliderEffort =
    activeModel?.id === props.model
      ? props.effort
      : (staged ?? effortFor(activeModel?.id ?? "", data.recents, data.current));

  const openChange = (next: boolean) => {
    intent.cancel();
    setOpen(next);
    setQuery("");
    setExpanded(new Set());
    setPreview({});
    setFocus("model");
    setActive({});
    setStaged(undefined);
  };
  const run = (node: MenuNode) => {
    intent.cancel();
    if (!node.run) return;
    if (node.run() !== "keep") openChange(false);
  };
  const previewRow = (target: ColumnId, key: string) => {
    if (target === "provider" && key.startsWith("provider:")) setPreview({ provider: key.slice("provider:".length) });
    else if (target === "family" && key.startsWith("family:"))
      setPreview((current) => ({ ...current, family: key.slice("family:".length) }));
  };
  const hover = (target: Column, node: MenuNode) => {
    setFocus(target.id);
    setActive((current) => ({ ...current, [target.id]: node.key }));
    if (target.id !== "provider" && target.id !== "family") {
      intent.cancel();
      return;
    }
    const next = columns[columns.indexOf(target) + 1];
    intent.schedule(
      () => previewRow(target.id, node.key),
      () => next && menu.current?.querySelector(`[data-column="${next.id}"]`),
    );
  };
  const filter = (next: string) => {
    setQuery(next);
    setActive({});
    setFocus(next ? "filter" : "model");
  };
  const keyDown = (event: React.KeyboardEvent) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      if (query) filter("");
      else openChange(false);
      return;
    }
    const recent = recentKey(event, query);
    if (recent !== undefined) {
      const combo = data.numbered[recent];
      if (combo) {
        props.onLand(combo.model, combo.effort);
        openChange(false);
      }
      return;
    }
    const at = columns.indexOf(column);
    const key = activeIn(column);
    const index = column.nodes.findIndex((node) => node.key === key);
    if (event.key === "ArrowUp" || event.key === "ArrowDown") {
      event.preventDefault();
      if (column.nodes.length === 0) return;
      const step = event.key === "ArrowDown" ? 1 : -1;
      const next = column.nodes[(Math.max(index, 0) + step + column.nodes.length) % column.nodes.length]!;
      setActive((current) => ({ ...current, [column.id]: next.key }));
      previewRow(column.id, next.key);
    } else if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      const next = columns[at + (event.key === "ArrowRight" ? 1 : -1)];
      if (next) setFocus(next.id);
    } else if (event.key === "Enter") {
      event.preventDefault();
      const node = column.nodes[index];
      if (node) run(node);
    } else if (event.key === "Tab") openChange(false);
    else typeKey(event, query, filter);
  };
  const focusKey = activeIn(column);
  return (
    <ModelPickerShell
      variant="columns"
      chip={props.label}
      open={open}
      onOpenChange={openChange}
      onKeyDown={keyDown}
      onPointerMove={(event) => intent.track(event)}
      activeId={focusKey && rowId(idPrefix, columns.indexOf(column), focusKey)}
      trigger={trigger}
      menu={menu}
    >
      <div className={`acpmux-menu-search${query ? "" : " acpmux-menu-search-empty"}`} aria-live="polite">
        <SearchIcon />
        <span>{query || t("picker.search")}</span>
      </div>
      <div className="acpmux-mp-grid">
        {columns.map((target, at) => {
          const highlight = activeIn(target);
          return (
            <div
              key={target.id}
              className={`acpmux-mp-column${target === column ? " acpmux-mp-column-focus" : ""}`}
              data-column={target.id}
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="group"
              aria-label={target.title}
              onPointerEnter={() => {
                if (target.id === "model" || target.id === "filter") intent.cancel();
              }}
            >
              <div className="acpmux-menu-header">{target.title}</div>
              <div className="acpmux-mp-column-rows">
                {target.nodes.map((node) => (
                  <MenuRow
                    key={node.key}
                    node={node}
                    id={rowId(idPrefix, at, node.key)}
                    active={node.key === highlight && (target === column || node.key === target.selected)}
                    open={node.key === target.selected && target.id !== "harness"}
                    onHover={() => hover(target, node)}
                    onPick={() => run(node)}
                  />
                ))}
              </div>
            </div>
          );
        })}
      </div>
      {props.efforts.length > 0 && (
        <div className="acpmux-mp-reasoning">
          <div className="acpmux-mp-reasoning-label">
            <span>{t("picker.reasoning")}</span>
            <span className="acpmux-mp-detail">
              {[activeModel?.name, data.effortName(sliderEffort)].filter(Boolean).join(" · ")}
            </span>
          </div>
          <EffortTrack
            efforts={props.efforts}
            current={sliderEffort}
            onEscape={() => trigger.current?.focus()}
            onPick={(value) => {
              if (!activeModel || activeModel.id === props.model) {
                setStaged(undefined);
                props.onEffort(value);
              } else setStaged(value);
            }}
          />
        </div>
      )}
      {data.numbered.length > 0 && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="acpmux-mp-strip" role="group" aria-label={t("picker.recent")}>
          {data.numbered.map((combo, index) => (
            <MenuRow
              key={`recent:${index}`}
              node={{
                key: `recent:${index}`,
                label: data.taxonomy.byId.get(combo.model)?.name ?? combo.model,
                detail: data.comboEffort(combo),
                hint: String(index + 1),
                checked: data.isCurrentCombo(combo),
              }}
              id={`${idPrefix}-recent-${index}`}
              active={false}
              onHover={() => intent.cancel()}
              onPick={() => {
                props.onLand(combo.model, combo.effort);
                openChange(false);
              }}
            />
          ))}
        </div>
      )}
    </ModelPickerShell>
  );
}

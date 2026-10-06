// What the model picker shows, built from the current harness's catalog and the
// viewer's recents: the shared derived data, the keys both layouts handle the same way, and
// the rows of the layered (cascade and drill) menus.
import type React from "react";
import { AgentMark } from "../shared/AgentMark";
import type { Combo } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { EffortTrack } from "./EffortTrack";
import type { Translate } from "./i18n";
import {
  buildTaxonomy,
  familyDefault,
  filterModels,
  fold,
  landOnFamily,
  landOnModel,
  landOnProvider,
  providerDefault,
  rankFamilies,
  rankModels,
  rankProviders,
  runnableRecents,
  type Current,
  type Landing,
  type TaxFamily,
  type TaxModel,
  type TaxProvider,
} from "./modelTaxonomy";
import { LEVEL_ROWS, RECENT_ROWS, type ModelPickerProps } from "./modelPickerLayout";
import type { MenuNode } from "./useMenuTree";

export type PickerData = ReturnType<typeof pickerData>;

/// The current harness's models as layers, with what the session runs and the recents it can run.
/// Models of other harnesses never enter: every row comes from this taxonomy.
export function pickerData(props: ModelPickerProps) {
  const entry = props.catalog.find((harness) => harness.id === props.harness);
  const taxonomy = buildTaxonomy(entry?.models ?? [], entry?.name ?? props.harness ?? "");
  const current: Current = { model: props.model, effort: props.effort };
  const recents = runnableRecents(props.recents, taxonomy, props.harness, Number.MAX_SAFE_INTEGER);
  const numbered = recents.slice(0, RECENT_ROWS);
  const model = taxonomy.byId.get(props.model ?? "");
  const provider = taxonomy.providers.find((candidate) => candidate.name === model?.provider);
  const family = provider?.families.find((candidate) => candidate.name === model?.family);
  const effortName = (id?: string) => props.efforts.find((choice) => choice.id === id)?.name ?? id;
  // A recent at the agent's default reasoning names only its model.
  const comboEffort = (combo: Combo) =>
    combo.effort && !isDefaultChoice({ id: combo.effort, name: combo.effortName })
      ? (combo.effortName ?? effortName(combo.effort))
      : undefined;
  // The catalog's default model, which the taxonomy leaves out of its providers.
  const defaultChoice = entry?.models.find((candidate) => isDefaultChoice(candidate));
  // Other harnesses are offered only as a new chat, and only when the pane can start one.
  const harnesses = props.catalog.filter((harness) => harness.id === props.harness || props.onHarness);
  const land = (landing: Landing | undefined) => {
    if (landing) props.onLand(landing.model, landing.effort);
  };
  return {
    taxonomy,
    current,
    recents,
    numbered,
    model,
    provider,
    family,
    harnesses,
    harnessName: entry?.name ?? props.harness ?? "",
    defaultChoice,
    effortName,
    comboEffort,
    isCurrentCombo: (combo: Combo) =>
      combo.model === props.model && (combo.effort ?? undefined) === (props.effort ?? undefined),
    landModel: (target: TaxModel) => land(landOnModel(target, recents, current)),
    landFamily: (target: TaxFamily) => land(landOnFamily(target, recents, current)),
    landProvider: (target: TaxProvider) => land(landOnProvider(target, recents, current)),
    landCombo: (combo: Combo) => props.onLand(combo.model, combo.effort),
    rankModels: (models: TaxModel[]) => rankModels(models, recents, current),
    rankFamilies: (families: TaxFamily[]) => rankFamilies(families, recents, current),
    rankProviders: (providers: TaxProvider[]) => rankProviders(providers, recents, current),
    filter: (query: string, within?: TaxModel[]) => {
      const matches = filterModels(taxonomy, query);
      return within ? matches.filter((match) => within.includes(match)) : matches;
    },
  };
}

/// Type-to-filter keys shared by both layouts: letters and digits (a digit no recent took, so "5"
/// finds GPT-5) and, once a query has begun, spaces extend the query, Backspace trims it. Returns
/// whether it took the key.
export function typeKey(event: React.KeyboardEvent, query: string, setQuery: (query: string) => void): boolean {
  if (event.metaKey || event.ctrlKey || event.altKey) return false;
  if (event.key === "Backspace") {
    if (!query) return false;
    event.preventDefault();
    setQuery(query.slice(0, -1));
    return true;
  }
  if (event.key.length !== 1) return false;
  if (!query && event.key === " ") return false;
  event.preventDefault();
  setQuery(query + event.key);
  return true;
}

/// With no query typed, 1 to `count` pick that numbered recent; returns its index. Other digits
/// are left to type-to-filter.
export function recentKey(event: React.KeyboardEvent, query: string, count: number): number | undefined {
  if (query || event.metaKey || event.ctrlKey || event.altKey || !/^[1-9]$/.test(event.key)) return undefined;
  if (Number(event.key) > count) return undefined;
  event.preventDefault();
  return Number(event.key) - 1;
}

type Order = "bestFirst" | "bestLast";
const ordered = <T,>(items: T[], order: Order) => (order === "bestLast" ? [...items].reverse() : items);

/// A level that shows its best LEVEL_ROWS rows and folds the rest under "More…", which expands
/// in place. The fold sits at the far end from the best row.
export function folded<T>(
  t: Translate,
  key: string,
  ranked: T[],
  row: (item: T) => MenuNode,
  order: Order,
  expanded: ReadonlySet<string>,
  expand: (key: string) => void,
): MenuNode[] {
  const { visible, hidden } = fold(ranked, LEVEL_ROWS, expanded.has(key));
  const rows = visible.map(row);
  if (hidden === 0) return ordered(rows, order);
  const more: MenuNode = {
    key: `${key}:more`,
    section: rows[0]?.section,
    label: t("picker.more"),
    detail: String(hidden),
    more: true,
    run: () => {
      expand(key);
      return "keep";
    },
  };
  return order === "bestLast" ? [more, ...ordered(rows, order)] : [...rows, more];
}

/// One harness choice: the current one checked, another as a new chat. One acpmux cannot start
/// (`unavailable`) says so and opens its reason with Try again instead of starting a chat that
/// fails seconds later; one whose switch just failed says so (`harnessNotes`). Resting on an
/// available one sends the prewarm hint; picking it switches.
export function harnessNode(
  harness: { id: string; name: string; unavailable?: string },
  props: ModelPickerProps,
  t: Translate,
  section?: string,
): MenuNode {
  const node = {
    key: `harness:${harness.id}`,
    label: harness.name,
    icon: <AgentMark agent={harness.id} size={14} />,
    section,
    checked: harness.id === props.harness,
  };
  if (harness.unavailable && harness.id !== props.harness)
    return {
      ...node,
      detail: t("picker.unavailable"),
      children: [
        { key: `harness:${harness.id}:reason`, label: harness.unavailable },
        { key: `harness:${harness.id}:retry`, label: t("picker.tryAgain"), run: () => props.onHarness?.(harness.id) },
      ],
    };
  return {
    ...node,
    detail: props.harnessNotes?.[harness.id] ?? (harness.id === props.harness ? undefined : t("picker.newChat")),
    rest: () => props.onHarnessHint?.(harness.id),
    run: () => {
      if (harness.id !== props.harness) props.onHarness?.(harness.id);
    },
  };
}

/// The builders for one open menu: rows for models, families, providers, harnesses, the
/// effort, the recents and a query's matches.
export function menuNodes(
  data: PickerData,
  props: ModelPickerProps,
  {
    order,
    expanded,
    expand,
    t,
  }: {
    order: Order;
    expanded: ReadonlySet<string>;
    expand(key: string): void;
    /** The caller's `useT()` translator. */
    t: Translate;
  },
) {
  const modelRow = (model: TaxModel, section?: string, detail?: string): MenuNode => ({
    key: `model:${model.id}`,
    label: model.name,
    detail,
    section,
    checked: model.id === props.model,
    run: () => data.landModel(model),
  });
  const familyModels = (family: TaxFamily, section?: string) =>
    folded(
      t,
      `family:${family.key}`,
      data.rankModels(family.models),
      (model) => modelRow(model, section),
      order,
      expanded,
      expand,
    );
  /// The current family's other models, for the top level: those the numbered recents don't
  /// already offer, so a row isn't listed twice.
  const currentFamily = (): MenuNode[] => {
    const family = data.family;
    if (!family) return [];
    const offered = new Set(data.numbered.map((combo) => combo.model));
    return folded(
      t,
      `current:${family.key}`,
      data.rankModels(family.models).filter((model) => !offered.has(model.id)),
      (model) => modelRow(model, family.name),
      order,
      expanded,
      expand,
    );
  };
  const familyRow = (family: TaxFamily, section?: string): MenuNode => ({
    key: `family:${family.key}`,
    label: family.name,
    detail: familyDefault(family, data.recents, data.current)?.name,
    section,
    run: () => data.landFamily(family),
    children: familyModels(family),
  });
  const families = (provider: TaxProvider, section?: string) =>
    folded(
      t,
      `families:${provider.name}`,
      data.rankFamilies(provider.families),
      (family) => familyRow(family, section),
      order,
      expanded,
      expand,
    );
  const providerRow = (provider: TaxProvider, section?: string): MenuNode => {
    return {
      key: `provider:${provider.name}`,
      label: provider.name,
      detail: providerDefault(provider, data.recents, data.current)?.name,
      section,
      run: () => data.landProvider(provider),
      children: families(provider),
    };
  };
  /// The agent's own default model: the model it resolves to with a "Default" hint, else
  /// "Default". Picking it keeps the session's effort.
  const defaultRow = (section?: string): MenuNode | undefined => {
    const choice = data.defaultChoice;
    if (!choice) return undefined;
    return {
      key: `model:${choice.id}`,
      label: props.resolvedDefault ?? t("picker.default"),
      detail: props.resolvedDefault ? t("picker.default") : undefined,
      section,
      checked: choice.id === props.model,
      run: () => props.onLand(choice.id),
    };
  };
  return {
    modelRow,
    defaultRow,
    familyModels,
    currentFamily,
    familyRow,
    providerRow,
    /// The layer above models: providers when the harness serves several, else the one provider's families.
    /// The agent's default model, when it has one, sits with them, nearest the best row.
    upperLayer(section = true): MenuNode[] {
      const providers = data.taxonomy.providers;
      const title = section ? t(providers.length === 1 ? "picker.family" : "picker.provider") : undefined;
      const rows =
        providers.length === 1
          ? families(providers[0]!, title)
          : folded(
              t,
              "providers",
              data.rankProviders(providers),
              (provider) => providerRow(provider, title),
              order,
              expanded,
              expand,
            );
      const fallback = defaultRow(title);
      if (!fallback) return rows;
      return order === "bestLast" ? [...rows, fallback] : [fallback, ...rows];
    },
    /// One row naming the harness; its submenu lists the catalog's harnesses, others as a new chat.
    harnessRow(): MenuNode | undefined {
      if (data.harnesses.length < 2) return undefined;
      return {
        key: "harness",
        label: data.harnessName,
        icon: props.harness ? <AgentMark agent={props.harness} size={14} /> : undefined,
        detail: t("picker.harness"),
        children: data.harnesses.map((harness) => harnessNode(harness, props, t)),
      };
    },
    /// The reasoning row: the current effort, with the slider as its submenu.
    effortRow(onEscape: () => void): MenuNode | undefined {
      if (props.efforts.length === 0) return undefined;
      const index = Math.max(
        0,
        props.efforts.findIndex((choice) => choice.id === props.effort),
      );
      return {
        key: "effort",
        label: t("picker.reasoning"),
        detail: data.effortName(props.effort),
        panel: (
          <EffortTrack efforts={props.efforts} current={props.effort} onPick={props.onEffort} onEscape={onEscape} />
        ),
        step: (delta) => {
          const next = props.efforts[index + delta];
          if (next) props.onEffort(next.id);
        },
      };
    },
    /// The numbered recents, 1 nearest the chip when the best row is last.
    recentRows(): MenuNode[] {
      const rows = data.numbered.map((combo, index): MenuNode => ({
        key: `recent:${index}`,
        label: data.taxonomy.byId.get(combo.model)?.name ?? combo.model,
        detail: data.comboEffort(combo),
        hint: String(index + 1),
        section: t("picker.recent"),
        checked: data.isCurrentCombo(combo),
        run: () => data.landCombo(combo),
      }));
      return ordered(rows, order);
    },
    /// A query's matches across this harness's models, best nearest the chip.
    matches(query: string, within?: TaxModel[]): MenuNode[] {
      const found = data.filter(query, within);
      if (found.length === 0) return [{ key: "none", label: t("picker.noMatches") }];
      return ordered(
        found.map((model) => modelRow(model, undefined, `${model.provider} · ${model.family}`)),
        order,
      );
    },
  };
}

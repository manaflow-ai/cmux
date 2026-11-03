// SPIKE (evidence, not production): can Base UI 1.8 carry the model picker with little wrapping?
// A composition of plain Base UI parts: Popover (trigger + popup) > Tabs (harness rail) +
// Autocomplete (inline, real DOM focus in its input, grouped rows) + ToggleGroup (effort) + Switch
// (Fast). Every line that is not plain Base UI composition sits in a block marked `WRAP <name>` and
// closed by `END WRAP`; scripts count them (spike report). The production picker
// (agent-session/acpmux/ModelPicker.tsx) is untouched.
import { useRef, useState, type KeyboardEvent, type PointerEvent as ReactPointerEvent } from "react";
import { Popover } from "@base-ui/react/popover";
import { Autocomplete } from "@base-ui/react/autocomplete";
import { Tabs } from "@base-ui/react/tabs";
import { ToggleGroup } from "@base-ui/react/toggle-group";
import { Toggle } from "@base-ui/react/toggle";
import { Switch } from "@base-ui/react/switch";
import { usePortalContainer } from "../UiProvider";
import { UI_ANCHOR_GAP } from "../anchor";
import { initials } from "../initials";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";

export interface SpikeModel {
  /** Base UI reads `{ value, label }` items with no itemToString of its own. */
  value: string;
  label: string;
  group?: string;
}
export interface SpikeHarness {
  id: string;
  name: string;
  models: readonly SpikeModel[];
  /** The harness is still reporting its models: the list shows the shared spinner. */
  loading?: boolean;
}
export type SpikeEffort = "low" | "medium" | "high" | "xhigh";
export interface BaseUiModelPickerProps {
  harnesses: readonly SpikeHarness[];
  harness: string;
  model?: string;
  effort?: SpikeEffort;
  efforts?: readonly SpikeEffort[];
  fast?: boolean;
  defaultOpen?: boolean;
  onPick?(harness: string, model: string): void;
  onEffort?(effort: SpikeEffort): void;
  onFast?(fast: boolean): void;
  onRefresh?(): void;
}

type Group = { value: string; items: SpikeModel[] };
const groupsOf = (models: readonly SpikeModel[]): Group[] => {
  const groups = new Map<string, SpikeModel[]>();
  for (const model of models) {
    const key = model.group ?? "Models";
    groups.set(key, [...(groups.get(key) ?? []), model]);
  }
  return [...groups].map(([value, items]) => ({ value, items }));
};

export function BaseUiModelPicker({
  harnesses,
  harness: committedHarness,
  model,
  effort = "medium",
  efforts = ["low", "medium", "high", "xhigh"],
  fast = false,
  defaultOpen = false,
  onPick,
  onEffort,
  onFast,
  onRefresh,
}: BaseUiModelPickerProps) {
  const container = usePortalContainer();
  const [open, setOpen] = useState(defaultOpen);
  const [tab, setTab] = useState(committedHarness);
  const [query, setQuery] = useState("");
  const input = useRef<HTMLInputElement>(null);
  const highlighted = useRef<SpikeModel | undefined>(undefined);
  const current = harnesses.find((entry) => entry.id === tab) ?? harnesses[0]!;
  const label = harnesses.flatMap((entry) => entry.models).find((entry) => entry.value === model)?.label ?? "Model";
  const show = (next: boolean) => {
    setOpen(next);
    if (!next) {
      setQuery("");
      setTab(committedHarness);
    }
  };

  // WRAP press-drag-release (trigger side). Base UI Popover.Trigger opens on `click` only (useClick
  // with no `event` option), so the press opens it here; Base UI's own click toggle is skipped for a
  // mouse click. Release on a row is native (Autocomplete.Item commits a highlighted row on a
  // mouseup that started elsewhere); release on a rail tab switches harness; release outside the
  // popup after a drag closes; release on the trigger, the search field or empty popup keeps it open.
  const press = useRef<{ x: number; y: number; moved: boolean } | null>(null);
  const onTriggerPointerDown = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (event.pointerType !== "mouse" || event.button !== 0) return;
    const trigger = event.currentTarget;
    const doc = trigger.ownerDocument;
    press.current = { x: event.clientX, y: event.clientY, moved: false };
    show(!open);
    const move = (moved: PointerEvent) => {
      const at = press.current;
      if (at && !at.moved) at.moved = Math.hypot(moved.clientX - at.x, moved.clientY - at.y) >= 4;
    };
    const up = (released: PointerEvent) => {
      doc.removeEventListener("pointermove", move, true);
      doc.removeEventListener("pointerup", up, true);
      const target = released.target instanceof Element ? released.target : null;
      const tabCell = target?.closest<HTMLElement>("[data-spike-harness]");
      if (tabCell) changeTab(tabCell.dataset.spikeHarness!);
      else if (press.current?.moved && !target?.closest(".spike-mp") && !trigger.contains(target)) show(false);
      press.current = null;
    };
    doc.addEventListener("pointermove", move, true);
    doc.addEventListener("pointerup", up, true);
  };
  // END WRAP

  // WRAP harness switch (keys and focus). Tabs.Tab activates on click and takes DOM focus; the
  // search field keeps it. Ctrl-[ / Ctrl-] step the rail from the field.
  const changeTab = (next: string) => {
    setTab(next);
    highlighted.current = undefined;
    input.current?.focus({ preventScroll: true });
  };
  const stepTab = (step: number) => {
    const at = harnesses.findIndex((entry) => entry.id === tab);
    changeTab(harnesses[(at + step + harnesses.length) % harnesses.length]!.id);
  };
  // END WRAP

  // WRAP ctrl-n/p/j/k. Base UI's ComboboxInput returns early on any modifier and has no imperative
  // highlight API, so the emacs/vi keys are replayed as the arrow they mean.
  const onInputKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (!event.ctrlKey || event.metaKey || event.altKey) return;
    const key = event.key.toLowerCase();
    const arrow = key === "n" || key === "j" ? "ArrowDown" : key === "p" || key === "k" ? "ArrowUp" : undefined;
    if (arrow) {
      event.preventDefault();
      const View = event.currentTarget.ownerDocument.defaultView!.KeyboardEvent;
      event.currentTarget.dispatchEvent(new View("keydown", { key: arrow, bubbles: true, cancelable: true }));
    } else if (key === "[" || key === "]") {
      event.preventDefault();
      stepTab(key === "]" ? 1 : -1);
    }
  };
  // END WRAP

  const groups = groupsOf(current.models);
  return (
    <Popover.Root open={open} onOpenChange={(next) => show(next)} modal={false}>
      <Popover.Trigger
        className="spike-mp-trigger"
        aria-label="Model"
        onPointerDown={onTriggerPointerDown}
        // WRAP press-drag-release: the mouse press already toggled; WebKit/Chromium must not move
        // focus to the trigger after Base UI focused the search field.
        onMouseDown={(event) => event.button === 0 && event.preventDefault()}
        onClick={(event) => {
          if (event.detail > 0) (event as typeof event & { preventBaseUIHandler(): void }).preventBaseUIHandler();
        }}
        // END WRAP
      >
        {label}
      </Popover.Trigger>
      <Popover.Portal container={container}>
        <Popover.Positioner className="ui-positioner" side="bottom" align="start" sideOffset={UI_ANCHOR_GAP}>
          <Popover.Popup className="ui-popup ui-glass spike-mp" aria-label="Choose a model" initialFocus={input}>
            <Tabs.Root className="spike-mp-body" orientation="vertical" value={tab} onValueChange={changeTab}>
              <Tabs.List className="spike-mp-rail" aria-label="Harness">
                {harnesses.map((entry) => (
                  <Tabs.Tab
                    key={entry.id}
                    value={entry.id}
                    className="spike-mp-rail-tab"
                    aria-label={entry.name}
                    title={entry.name}
                    data-spike-harness={entry.id}
                    // WRAP harness switch: a press on a tab keeps DOM focus in the search field.
                    onMouseDown={(event) => event.preventDefault()}
                    // END WRAP
                  >
                    {initials(entry.name)}
                  </Tabs.Tab>
                ))}
              </Tabs.List>
              <div className="spike-mp-main">
                <Autocomplete.Root
                  inline
                  open
                  items={groups}
                  value={query}
                  onValueChange={setQuery}
                  itemToStringValue={(item: SpikeModel) => item.label}
                  autoHighlight="always"
                  keepHighlight
                  onItemHighlighted={(item) => {
                    highlighted.current = item as SpikeModel | undefined;
                  }}
                  // WRAP pick: Base UI reports a row press (click, drag-release mouseup, Return) as
                  // a close with reason item-press but not which row; the highlight is that row.
                  onOpenChange={(_, details) => {
                    if (details.reason !== "item-press" || !highlighted.current) return;
                    onPick?.(current.id, highlighted.current.value);
                    show(false);
                  }}
                  // END WRAP
                >
                  <Autocomplete.Input
                    ref={input}
                    className="spike-mp-search"
                    placeholder="Search models"
                    aria-label="Search models"
                    onKeyDown={onInputKeyDown}
                  />
                  {current.loading ? (
                    <output className="spike-mp-status">
                      <Spinner loading size={14} /> Loading models
                    </output>
                  ) : (
                    <Autocomplete.Empty className="spike-mp-status">
                      {query.trim() ? (
                        "No matching models"
                      ) : (
                        <>
                          No models yet.{" "}
                          <button type="button" className="spike-mp-link" onClick={onRefresh}>
                            Refresh…
                          </button>
                        </>
                      )}
                    </Autocomplete.Empty>
                  )}
                  <Autocomplete.List className="spike-mp-list" hidden={current.loading}>
                    {(group: Group) => (
                      <Autocomplete.Group key={group.value} items={group.items} className="spike-mp-group">
                        <Autocomplete.GroupLabel className="spike-mp-group-label">
                          {group.value}
                        </Autocomplete.GroupLabel>
                        <Autocomplete.Collection>
                          {(item: SpikeModel) => (
                            <Autocomplete.Item
                              key={item.value}
                              value={item}
                              className="spike-mp-row"
                              aria-current={item.value === model && current.id === committedHarness ? true : undefined}
                            >
                              <span className="spike-mp-row-label">{item.label}</span>
                            </Autocomplete.Item>
                          )}
                        </Autocomplete.Collection>
                      </Autocomplete.Group>
                    )}
                  </Autocomplete.List>
                </Autocomplete.Root>
                <div className="spike-mp-controls">
                  <ToggleGroup
                    className="spike-mp-effort"
                    aria-label="Effort"
                    value={[effort]}
                    onValueChange={(next) => next[0] && onEffort?.(next[0] as SpikeEffort)}
                  >
                    {efforts.map((level) => (
                      <Toggle key={level} value={level} className="spike-mp-effort-seg">
                        {level}
                      </Toggle>
                    ))}
                  </ToggleGroup>
                  <span className="spike-mp-fast">
                    Fast
                    <Switch.Root
                      className="spike-mp-switch"
                      aria-label="Fast"
                      checked={fast}
                      onCheckedChange={(next) => onFast?.(next)}
                    >
                      <Switch.Thumb className="spike-mp-switch-thumb" />
                    </Switch.Root>
                  </span>
                </div>
              </div>
            </Tabs.Root>
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

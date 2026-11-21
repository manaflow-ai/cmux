// The composer footer's extension controls (`cmux.composer.control/1`): an app's buttons and menus,
// drawn as the composer's own Plan toggle and pickers are. A click writes the control's text at the
// caret (`onInsert`) or asks the daemon to run its action as the app (extensionControls.ts).
import { SceneSymbol } from "../../../apps/scene/SceneSymbol";
import type { PageClient } from "../../../pages/shared/pageClient";
import { ChevronIcon, Picker } from "../ComposerPickers";
import { tooltipProps } from "../shortcuts";
import { type ExtensionControl, type ExtensionControlItem, runExtensionControl } from "./extensionControls";

export function ExtensionControls({
  controls,
  placement,
  client,
  onInsert,
}: {
  controls: readonly ExtensionControl[];
  placement: "left" | "right";
  client: PageClient | null;
  onInsert(text: string): void;
}) {
  const shown = controls.filter((control) => control.placement === placement);
  if (!shown.length) return null;
  const run = (control: ExtensionControl, item?: ExtensionControlItem) => {
    // Called in the click itself, so the host sees the person's gesture.
    void runExtensionControl(client, control, item)
      .then((insert) => insert && onInsert(insert))
      .catch(() => undefined);
  };
  return (
    <>
      {shown.map((control) =>
        control.kind === "menu" ? (
          <Picker
            key={`${control.app}/${control.id}`}
            // The opener key names the app, so an app's menu never takes a built-in picker's name.
            label={`${control.extension}: ${control.label}`}
            className="acpmux-extension-control"
            tooltip={control.tooltip ?? control.label}
            align={placement === "left" ? "start" : "end"}
            heading={control.label}
            button={
              <>
                {control.symbol && <SceneSymbol symbol={control.symbol} size={14} />}
                <span>{control.label}</span>
                <ChevronIcon />
              </>
            }
            sections={[
              {
                choices: control.items.map((item) => ({
                  id: item.id,
                  name: item.label,
                  ...(item.description && { description: item.description }),
                  ...(item.symbol && { icon: <SceneSymbol symbol={item.symbol} size={14} /> }),
                })),
                onPick: (id) => {
                  const item = control.items.find((entry) => entry.id === id);
                  if (item) run(control, item);
                },
              },
            ]}
          />
        ) : (
          <button
            key={`${control.app}/${control.id}`}
            type="button"
            className="acpmux-plan acpmux-extension-control"
            aria-label={control.label}
            data-extension-control={`${control.app}/${control.id}`}
            {...tooltipProps(control.tooltip ?? control.label, undefined)}
            onClick={() => run(control)}
          >
            {control.symbol ? <SceneSymbol symbol={control.symbol} size={14} /> : <span>{control.label}</span>}
          </button>
        ),
      )}
    </>
  );
}

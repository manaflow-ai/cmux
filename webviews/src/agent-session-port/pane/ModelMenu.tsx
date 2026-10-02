// The model chip's popover (model-menu.png): the effort as a title and a stepped slider,
// the model name under it; the agent's models follow as a plain list.
import { Popover } from "../shell/Popover";
import { COMPOSER_ANCHORS } from "../shell/anchors";
import { IconCheck } from "../shell/icons";
import "../app/menus.css";

export type Choice = { id: string; name: string };

/** Slider geometry of the reference: stops 51px apart from 13px in a 230px track. */
const FIRST_STOP = 13;
const TRACK = 204;

export function ModelMenu({
  models,
  model,
  efforts,
  effort,
  onModel,
  onEffort,
  onDismiss,
}: {
  models: Choice[];
  model?: string;
  efforts: Choice[];
  effort?: string;
  onModel: (id: string) => void;
  onEffort: (id: string) => void;
  onDismiss: () => void;
}) {
  const level = Math.max(
    0,
    efforts.findIndex((choice) => choice.id === effort),
  );
  const step = efforts.length > 1 ? TRACK / (efforts.length - 1) : 0;
  const x = FIRST_STOP + level * step;
  const current = models.find((choice) => choice.id === model);
  return (
    <Popover anchor={COMPOSER_ANCHORS.model} onDismiss={onDismiss} className="app-effort-pop pt-model-pop">
      {efforts.length > 0 && (
        <>
          <div className="app-effort-pop__title">{efforts[level]?.name}</div>
          <div className="app-effort-pop__model">{current?.name ?? model}</div>
          <div className="app-slider">
            <div className="app-slider__fill" style={{ width: x }} />
            {efforts.map((choice, index) =>
              index === level ? null : (
                <button
                  type="button"
                  key={choice.id}
                  className="app-slider__dot pt-slider__stop"
                  style={{ left: FIRST_STOP + index * step }}

                  aria-label={choice.name}
                  onClick={() => onEffort(choice.id)}
                />
              ),
            )}
            <span className="app-slider__thumb" style={{ left: x }} />
          </div>
        </>
      )}
      {models.length > 1 && (
        <div className="pt-model-list" role="menu">
          {models.map((choice) => (
            <button
              type="button"
              key={choice.id}
              className="pt-model-list__item"
              role="menuitemradio"
              aria-checked={choice.id === model}
              onClick={() => onModel(choice.id)}
            >
              <span>{choice.name}</span>
              {choice.id === model && <IconCheck size={14} strokeWidth={1.4} />}
            </button>
          ))}
        </div>
      )}
    </Popover>
  );
}

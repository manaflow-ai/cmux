// The collage editor (backgrounds plan phase 7): pictures on a 16:10 canvas over a fill. Drag a
// picture to move it, drag its corner to resize it; edges snap to the canvas's halves and thirds.
// Arrow keys nudge the chosen picture (Shift: further), Delete removes it. Saving draws the
// collage natively (BackdropCollages) and makes it the background.
import { useRef, useState } from "react";
import { useSettingsState, useStore } from "../context";
import { t } from "../strings";
import {
  arranged,
  type Collage,
  type CollageLayoutName,
  MAX_LAYERS,
  moved,
  placed,
  resized,
  restacked,
} from "./collageLayout";

const REFUSALS: Record<string, string> = {
  "cmux.settings.backdrop.collage.no_pictures": "settingsWindow.collage.noPictures",
};

const thumbnail = (id: string) => `backdrop/${encodeURIComponent(encodeURIComponent(id))}`;

export function CollageEditor({
  start,
  replacing,
  onClose,
}: {
  start?: Collage;
  /** The collage this edits; saving replaces it. */
  replacing?: string;
  onClose: () => void;
}) {
  const store = useStore();
  const { host } = useSettingsState();
  const [collage, setCollage] = useState<Collage>(start ?? { name: "", fill: "#101010", layers: [] });
  const [chosen, setChosen] = useState<number | null>(null);
  const [adding, setAdding] = useState(false);
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const canvas = useRef<HTMLDivElement | null>(null);
  const drag = useRef<{ index: number; mode: "move" | "resize"; x: number; y: number } | null>(null);
  // Stills only: art, macOS stills and your own images (no video, desktop or collage).
  const pictures = (host?.backdrops ?? []).filter(
    (choice) =>
      !choice.video && choice.downloaded !== false && choice.id !== "desktop" && !choice.id.startsWith("collage:"),
  );
  const update = (index: number, change: (layer: Collage["layers"][number]) => Collage["layers"][number]) =>
    setCollage((c) => ({ ...c, layers: c.layers.map((layer, i) => (i === index ? change(layer) : layer)) }));
  const remove = (index: number) => {
    setCollage((c) => ({ ...c, layers: c.layers.filter((_, i) => i !== index) }));
    setChosen(null);
  };
  const add = (source: string) => {
    setCollage((c) => ({ ...c, layers: [...c.layers, placed(source, c.layers.length)] }));
    setChosen(collage.layers.length);
    setAdding(false);
  };
  const restack = (by: number) => {
    if (chosen === null) return;
    setCollage((c) => ({ ...c, layers: restacked(c.layers, chosen, by) }));
    setChosen(Math.min(Math.max(chosen + by, 0), collage.layers.length - 1));
  };
  const layout = (name: CollageLayoutName) => setCollage((c) => arranged(c, name));
  const save = async () => {
    setBusy(true);
    setRefusal(null);
    const result = await store.saveCollage(collage, replacing);
    setBusy(false);
    if ("id" in result) onClose();
    else setRefusal(t(REFUSALS[result.error] ?? "settingsWindow.collage.invalid"));
  };
  const pointer = (event: React.PointerEvent) => {
    const box = canvas.current?.getBoundingClientRect();
    const current = drag.current;
    if (!box || !current || box.width === 0) return;
    const dx = (event.clientX - current.x) / box.width;
    const dy = (event.clientY - current.y) / box.height;
    current.x = event.clientX;
    current.y = event.clientY;
    update(current.index, (layer) => (current.mode === "move" ? moved(layer, dx, dy) : resized(layer, dx, dy)));
  };
  const keys = (event: React.KeyboardEvent) => {
    if (chosen === null) return;
    const step = event.shiftKey ? 0.05 : 0.01;
    const nudges: Record<string, [number, number]> = {
      ArrowLeft: [-step, 0],
      ArrowRight: [step, 0],
      ArrowUp: [0, -step],
      ArrowDown: [0, step],
    };
    const nudge = nudges[event.key];
    if (nudge) {
      event.preventDefault();
      update(chosen, (layer) => moved(layer, nudge[0], nudge[1]));
    } else if (event.key === "Delete" || event.key === "Backspace") {
      event.preventDefault();
      remove(chosen);
    }
  };
  const layer = chosen !== null ? collage.layers[chosen] : undefined;
  return (
    <div className="art-browser collage-editor" data-card="collage-editor">
      <div className="art-browser-search">
        <input
          className="field"
          aria-label={t("settingsWindow.collage.name")}
          placeholder={t("settingsWindow.collage.name")}
          value={collage.name}
          maxLength={100}
          onChange={(event) => setCollage((c) => ({ ...c, name: event.target.value }))}
        />
        <label className="row-help collage-fill">
          {t("settingsWindow.collage.fill")}
          <input
            type="color"
            aria-label={t("settingsWindow.collage.fill")}
            value={collage.fill}
            onChange={(event) => setCollage((c) => ({ ...c, fill: event.target.value.toUpperCase() }))}
          />
        </label>
      </div>
      <div ref={canvas} className="collage-canvas" style={{ background: collage.fill }}>
        {collage.layers.map((item, index) => {
          const frame = {
            left: `${item.x * 100}%`,
            top: `${item.y * 100}%`,
            width: `${item.width * 100}%`,
            height: `${item.height * 100}%`,
          };
          const grab = (mode: "move" | "resize") => (event: React.PointerEvent<HTMLButtonElement>) => {
            setChosen(index);
            drag.current = { index, mode, x: event.clientX, y: event.clientY };
            event.currentTarget.setPointerCapture?.(event.pointerId);
          };
          const release = () => (drag.current = null);
          return (
            <span key={`${item.source}-${index}`}>
              <button
                type="button"
                className={index === chosen ? "collage-layer chosen" : "collage-layer"}
                aria-label={pictures.find((choice) => choice.id === item.source)?.title ?? item.source}
                aria-pressed={index === chosen}
                style={{ ...frame, opacity: item.opacity, borderRadius: `${item.cornerRadius * 100}%` }}
                onFocus={() => setChosen(index)}
                onKeyDown={keys}
                onPointerDown={grab("move")}
                onPointerMove={pointer}
                onPointerUp={release}
                onPointerCancel={release}
              >
                <img src={thumbnail(item.source)} alt="" draggable={false} />
              </button>
              {index === chosen && (
                <button
                  type="button"
                  className="collage-handle"
                  aria-label={t("settingsWindow.collage.resize")}
                  style={{
                    left: `calc(${(item.x + item.width) * 100}% - 12px)`,
                    top: `calc(${(item.y + item.height) * 100}% - 12px)`,
                  }}
                  onPointerDown={grab("resize")}
                  onPointerMove={pointer}
                  onPointerUp={release}
                  onPointerCancel={release}
                />
              )}
            </span>
          );
        })}
      </div>
      <p className="row-help">{t("settingsWindow.collage.hint")}</p>
      <div className="backdrop-own-bar">
        <button
          type="button"
          className="button"
          disabled={collage.layers.length >= MAX_LAYERS}
          aria-expanded={adding}
          onClick={() => setAdding((open) => !open)}
        >
          {t("settingsWindow.collage.add")}
        </button>
        <button type="button" className="button" onClick={() => layout("two")}>
          {t("settingsWindow.collage.layoutTwo")}
        </button>
        <button type="button" className="button" onClick={() => layout("three")}>
          {t("settingsWindow.collage.layoutThree")}
        </button>
        <button type="button" className="button" onClick={() => layout("mosaic")}>
          {t("settingsWindow.collage.layoutMosaic")}
        </button>
      </div>
      {layer && chosen !== null && (
        <div className="backdrop-own-bar">
          <button type="button" className="button" onClick={() => restack(1)}>
            {t("settingsWindow.collage.forward")}
          </button>
          <button type="button" className="button" onClick={() => restack(-1)}>
            {t("settingsWindow.collage.backward")}
          </button>
          <label className="row-help">
            {t("settingsWindow.collage.corners")}
            <input
              type="range"
              min={0}
              max={0.5}
              step={0.01}
              value={layer.cornerRadius}
              aria-label={t("settingsWindow.collage.corners")}
              onChange={(event) => update(chosen, (item) => ({ ...item, cornerRadius: Number(event.target.value) }))}
            />
          </label>
          <button type="button" className="button" onClick={() => remove(chosen)}>
            {t("settingsWindow.collage.removeLayer")}
          </button>
        </div>
      )}
      {adding && (
        <div className="backdrop-grid" data-card="collage-pictures">
          {pictures.map((choice) => (
            <button
              key={choice.id}
              type="button"
              className="backdrop-tile"
              aria-label={choice.title}
              onClick={() => add(choice.id)}
            >
              <img className="backdrop-thumb" alt="" src={thumbnail(choice.id)} />
              <span className="backdrop-title">{choice.title}</span>
            </button>
          ))}
        </div>
      )}
      <div className="backdrop-own-bar">
        <button
          type="button"
          className="button"
          disabled={busy || collage.layers.length === 0}
          onClick={() => void save()}
        >
          {t("settingsWindow.collage.save")}
        </button>
        <button type="button" className="button" onClick={onClose}>
          {t("settingsWindow.collage.cancel")}
        </button>
        <output className="row-help">{refusal}</output>
      </div>
    </div>
  );
}

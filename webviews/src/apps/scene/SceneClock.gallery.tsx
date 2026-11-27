// l10n-allow-file: gallery fixture text, not shipped UI.
// The scene vocabulary Apple's clock and calendar widgets need, drawn by the web scene renderer from
// plain scene ops: Text `fontDesign` (heavy and rounded is the Lock Screen's time), HStack
// `firstTextBaseline` (AM/PM beside the big time), host-ticking date Text (`date`, `dateStyle`: the
// renderer counts, the app sends nothing), Capsule hands turned with `rotation` and `offset`,
// `frame({maxHeight: "infinity"})` filling the tile, and ZStack `position` (a day's hour grid with its
// events and now line). The tile stands in for the widget host's card at Apple's widget sizes
// (small 170, medium 364 x 170, large 364 x 382).
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp, type SceneProps } from "./store";
import "./SceneClock.gallery.css";

type Look = "rounded" | "ticking" | "analog" | "bar" | "calendar-day" | "fill";
type Size = "small" | "medium" | "large";
type Props = { look?: Look; all?: boolean };

/** A scene built as a tree: `node(type, props, children)` then `scene(root)` gives its ops. */
type Node = { type: string; props?: SceneProps; children?: Node[] };
const node = (type: string, props: SceneProps = {}, children: Node[] = []): Node => ({ type, props, children });

function scene(root: Node): SceneOp[] {
  const ops: SceneOp[] = [];
  let next = 0;
  const walk = (n: Node): string => {
    const id = `n${next++}`;
    ops.push({ op: "create", id, type: n.type, props: n.props });
    const kids = (n.children ?? []).map(walk);
    if (kids.length) ops.push({ op: "children", id, children: kids });
    return id;
  };
  ops.push({ op: "root", id: walk(root) });
  return ops;
}

const fill = { maxWidth: "infinity", maxHeight: "infinity" };
const text = (value: string, props: SceneProps = {}) => node("Text", { text: value, ...props });

/** The Lock Screen's time: heavy, rounded, with a baseline-aligned AM. */
function roundedTime(): Node {
  return node("VStack", { alignment: "leading", padding: 16, frame: fill }, [
    text("MONDAY", { font: 12, weight: "semibold", color: "danger" }),
    text("November 16", { font: 15, weight: "semibold", fontDesign: "rounded", color: "secondary" }),
    node("Spacer"),
    node("HStack", { alignment: "firstTextBaseline", spacing: 2 }, [
      // Sized to a small tile's 138 pt content width: 9:41 and AM side by side, never wrapped.
      text("9:41", { font: 44, weight: "heavy", fontDesign: "rounded", lineLimit: 1, fixedSize: "horizontal" }),
      text("AM", {
        font: 17,
        weight: "bold",
        fontDesign: "rounded",
        color: "secondary",
        lineLimit: 1,
        fixedSize: "horizontal",
      }),
    ]),
  ]);
}

/** A time and a timer the renderer ticks itself, and how long ago the timer started. */
function ticking(): Node {
  const now = Date.now();
  return node("VStack", { alignment: "leading", spacing: 2, padding: 16, frame: fill }, [
    text("", {
      date: now,
      dateStyle: "time",
      font: 28,
      lineLimit: 1,
      weight: "heavy",
      fontDesign: "rounded",
      contentTransition: "numericText",
    }),
    text("", { date: now, dateStyle: "date", font: 12, color: "secondary" }),
    node("Spacer"),
    node("HStack", { alignment: "firstTextBaseline", spacing: 6 }, [
      node("Icon", { symbol: "timer", size: 13, color: "warning" }),
      text("Focus", { font: 13, weight: "semibold", color: "warning" }),
    ]),
    text("", { date: now + 25 * 60_000, dateStyle: "timer", font: 28, weight: "semibold", fontDesign: "monospaced" }),
    text("", { date: now - 4 * 60_000, dateStyle: "relative", font: 11, color: "tertiary" }),
  ]);
}

/** An analog face at 9:41:12: twelve ticks and Capsule hands, each offset by half its length and
 * turned about the face's center. */
function analog(): Node {
  const [h, m, s] = [9, 41, 12];
  const face = 132;
  const hand = (width: number, length: number, degrees: number, fillTone: string) =>
    node("Capsule", {
      frame: { width, height: length },
      fill: fillTone,
      offset: { y: -length / 2 + width / 2 },
      rotation: degrees,
      animation: "smooth",
    });
  const ticks = Array.from({ length: 12 }, (_, i) =>
    node("Capsule", {
      frame: { width: i % 3 ? 2 : 3, height: i % 3 ? 6 : 10 },
      fill: i % 3 ? "tertiary" : "secondary",
      offset: { y: -face / 2 + 10 },
      rotation: i * 30,
    }),
  );
  return node("VStack", { alignment: "center", padding: 16, frame: fill }, [
    node("Spacer"),
    node("ZStack", { frame: { width: face, height: face } }, [
      node("Circle", { size: face, fill: "badge" }),
      ...ticks,
      hand(5, 36, (h % 12) * 30 + m / 2, "primary"),
      hand(3, 54, m * 6 + s / 10, "primary"),
      hand(1.5, 60, s * 6, "danger"),
      node("Circle", { size: 7, fill: "danger" }),
    ]),
    node("Spacer"),
  ]);
}

/** Calendar's Up Next: a full-height tinted bar beside each event, sized by the tile, not by points. */
function bar(): Node {
  const event = (title: string, time: string, place: string, tint: string) =>
    node("HStack", { spacing: 8, frame: { maxWidth: "infinity", maxHeight: "infinity" } }, [
      node("Capsule", { frame: { width: 4, maxHeight: "infinity" }, fill: tint }),
      node("VStack", { alignment: "leading", spacing: 2 }, [
        text(title, { font: 13, weight: "semibold", lineLimit: 1 }),
        text(time, { font: 12, color: "secondary" }),
        text(place, { font: 11, color: "tertiary" }),
      ]),
    ]);
  return node("HStack", { spacing: 16, padding: 16, frame: fill, alignment: "top" }, [
    node("VStack", { alignment: "leading", frame: { width: 96, maxHeight: "infinity" } }, [
      text("MONDAY", { font: 12, weight: "semibold", color: "danger" }),
      text("16", { font: 44, weight: "regular", fontDesign: "rounded" }),
      node("Spacer"),
      text("2 events", { font: 11, color: "tertiary" }),
    ]),
    node("VStack", { spacing: 8, frame: fill }, [
      event("Design review", "10:00 – 11:30 AM", "Room 4", "accent"),
      event("Lunch with Sam", "12:30 – 1:30 PM", "Cafe", "success"),
    ]),
  ]);
}

/** Apple's large Calendar day: an hour grid, two overlapping events sharing the width and the now
 * line, every one placed on the grid with ZStack `position` (the SDK's Timeline draws the same). */
function calendarDay(): Node {
  const [start, end, hourHeight, labelWidth, width] = [8, 13, 52, 40, 332];
  const grid = width - labelWidth;
  const y = (hour: number) => (hour - start) * hourHeight;
  const rows = Array.from({ length: end - start + 1 }, (_, i) =>
    // The row and its Line take the grid's width: a frameless Line is its parent's width, and a row
    // that only wraps its content would leave it none (and squeeze the hour label out).
    node("HStack", { spacing: 4, alignment: "top", frame: { width, height: i === end - start ? 1 : hourHeight } }, [
      text(`${(start + i) % 12 || 12} ${start + i < 12 ? "AM" : "PM"}`, {
        font: 11,
        color: "tertiary",
        lineLimit: 1,
        frame: { width: labelWidth - 4 },
        offset: { y: -6 },
      }),
      node("Line", { stroke: "separator", frame: { width: grid } }),
    ]),
  );
  const event = (title: string, from: number, to: number, lane: number, lanes: number, tint: string) => {
    const laneWidth = grid / lanes;
    const height = (to - from) * hourHeight - 2;
    return node(
      "VStack",
      {
        alignment: "leading",
        padding: { top: 4, leading: 6, trailing: 4 },
        frame: { width: laneWidth - 2, height },
        background: "selected",
        cornerRadius: 4,
        position: { x: labelWidth + laneWidth * (lane + 0.5), y: y(from) + height / 2 },
      },
      [
        text(title, { font: 11, weight: "semibold", color: tint, lineLimit: 1 }),
        text(`${Math.floor(from)}:${String(Math.round((from % 1) * 60)).padStart(2, "0")}`, {
          font: 11,
          color: "secondary",
        }),
      ],
    );
  };
  const now = 10.68; // 10:41
  return node("VStack", { alignment: "leading", spacing: 12, padding: 16, frame: fill }, [
    node("HStack", { alignment: "firstTextBaseline", spacing: 6 }, [
      text("Monday", { font: 15, weight: "semibold", color: "danger" }),
      text("November 16", { font: 15, weight: "semibold" }),
    ]),
    node("ZStack", { frame: { maxWidth: "infinity" } }, [
      node("VStack", { spacing: 0 }, rows),
      event("Standup", 9, 10, 0, 2, "accent"),
      event("Design review", 9.5, 11.5, 1, 2, "success"),
      event("Lunch", 12, 13, 0, 1, "warning"),
      node("Line", {
        stroke: "danger",
        strokeWidth: 1.5,
        frame: { width: grid },
        position: { x: labelWidth + grid / 2, y: y(now) },
      }),
      node("Circle", { size: 7, fill: "danger", position: { x: labelWidth, y: y(now) } }),
    ]),
  ]);
}

/** SwiftUI's flexible frame on both axes, with no Spacer: the condition column takes the row's free
 * width beside the temperature, the hourly bars fill the rest of the tile's height, and a ZStack card
 * fills its whole cell. */
function fillLook(): Node {
  const hours: Array<[string, number]> = [
    ["9", 0.35],
    ["10", 0.5],
    ["11", 0.7],
    ["12", 0.9],
    ["1", 1],
    ["2", 0.8],
  ];
  return node("VStack", { alignment: "leading", spacing: 8, padding: 16, frame: fill }, [
    node("HStack", { spacing: 8, alignment: "firstTextBaseline" }, [
      node(
        "VStack",
        { alignment: "leading", frame: { maxWidth: "infinity" }, background: "hover", cornerRadius: 6, padding: 4 },
        [text("Cupertino", { font: 13, weight: "semibold" }), text("Sunny", { font: 12, color: "secondary" })],
      ),
      text("72°", { font: 34, weight: "medium", fontDesign: "rounded" }),
    ]),
    node("HStack", { spacing: 6, alignment: "bottom", frame: { maxWidth: "infinity", maxHeight: "infinity" } }, [
      ...hours.map(([label, level]) =>
        node("VStack", { alignment: "center", spacing: 2, frame: { maxWidth: "infinity", maxHeight: "infinity" } }, [
          node("Spacer"),
          node("Capsule", {
            frame: { width: 8, height: Math.round(level * 56) },
            fill: level === 1 ? "warning" : "secondary",
          }),
          text(label, { font: 11, color: "tertiary" }),
        ]),
      ),
      node("ZStack", { frame: { width: 64, maxHeight: "infinity" } }, [
        node("RoundedRectangle", {
          frame: { maxWidth: "infinity", maxHeight: "infinity" },
          fill: "badge",
          cornerRadius: 8,
        }),
        text("UV 6", { font: 12, weight: "semibold" }),
      ]),
    ]),
  ]);
}

const LOOKS: Record<Look, { size: Size; build: () => Node }> = {
  fill: { size: "medium", build: fillLook },
  rounded: { size: "small", build: roundedTime },
  ticking: { size: "small", build: ticking },
  analog: { size: "small", build: analog },
  bar: { size: "medium", build: bar },
  "calendar-day": { size: "large", build: calendarDay },
};

function Tile({ look }: { look: Look }) {
  const { size, build } = LOOKS[look];
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(scene(build()), true);
    return s;
  });
  return (
    <div className="gallery-scene-clock-tile" data-size={size} data-look={look}>
      <SceneRenderer store={store} dispatch={() => {}} />
    </div>
  );
}

function SceneClock({ look = "rounded", all = false }: Props) {
  if (!all)
    return (
      <div className="gallery-scene-clock">
        <Tile look={look} />
      </div>
    );
  return (
    <div className="gallery-scene-clock">
      <div className="gallery-scene-clock-row">
        <Tile look="rounded" />
        <Tile look="ticking" />
        <Tile look="analog" />
      </div>
      <Tile look="bar" />
      <Tile look="fill" />
      <Tile look="calendar-day" />
    </div>
  );
}

export default componentEntry<Props>({
  id: "apps.scene-clock",
  title: "Scene clock vocabulary",
  area: "Apps",
  pane: true,
  height: 460,
  widths: { narrow: 420, normal: 600 },
  keywords: [
    "widget",
    "clock",
    "time",
    "timer",
    "calendar",
    "fontDesign",
    "rounded",
    "baseline",
    "rotation",
    "position",
    "Line",
  ],
  covers: [
    "apps/scene/SceneRenderer.tsx",
    "apps/scene/sceneDate.ts",
    "apps/scene/sceneStyle.ts",
    "apps/scene/scene.css",
  ],
  load: async () => SceneClock,
  variants: {
    rounded: {
      note: "Text fontDesign rounded at weight heavy (the Lock Screen's time), with AM on the first text baseline of the HStack.",
      props: { look: "rounded" },
    },
    ticking: {
      note: "Host-ticking Text: the time, the date, a 25-minute timer and a relative 'started' line, formatted and ticked by the renderer on one shared per-second clock. No scene batch per tick.",
      props: { look: "ticking" },
    },
    analog: {
      note: "An analog face: Capsule ticks and hands, each offset by half its length and turned with rotationEffect about the face's center. A change animates only under animation(), behind the motion gate.",
      props: { look: "analog" },
    },
    bar: {
      note: "frame({maxHeight: 'infinity'}): each event's tinted Capsule bar fills its row's height, and the rows fill the tile.",
      props: { look: "bar" },
    },
    fill: {
      note: "Flexible frames on both axes with no Spacer: maxWidth infinity takes the row's free width (the city column beside 72°), maxHeight infinity fills the tile's height (the hourly bars) and a ZStack card fills its cell.",
      props: { look: "fill" },
    },
    "calendar-day": {
      note: "Apple's large Calendar day: an hour grid of Lines, two overlapping events sharing the width and the now line, placed on the grid with ZStack position.",
      props: { look: "calendar-day" },
    },
    all: {
      note: "Every look side by side.",
      props: { all: true },
    },
  },
});

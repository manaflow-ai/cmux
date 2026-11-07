// The Messages page's large picture and video viewers, over the conversation's pane (a port of the
// native HomePictureViewer and HomeVideoViewer). A click on a picture opens it with the message's
// other pictures: it fits the pane and zooms (a pinch, Command-plus and -minus, Command-0 to fit,
// a double-click for its own size) and pans (scroll, or drag with Move). The arrow keys and the
// side buttons step through the pictures; C (or Compare) shows a picture and its neighbour with a
// slider. The tools mark it up (arrow, box, pen, text; Command-Z undoes); Send in Chat puts the
// marked picture in the message box, Copy and Save keep it. Escape leaves the words being typed,
// then the comparison, then closes. View Larger plays a video large from where its bubble was.
//
// Cost: one viewer at most; its listeners (the pinch's wheel, a drag's moves) end with it or the drag.
import {
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { Icon } from "../../../agent-session/acpmux/icons/Icon";
import { KeyboardScope } from "../../../ui/KeyboardScope";
import {
  AttachmentContext,
  AttachmentOpenContext,
  useImage,
  type AttachmentOpener,
} from "../../home-channels/AttachmentViews";
import { HomeIcon } from "../../home-channels/icons";
import type { HomeAttachment } from "../../home-channels/types";
import type { Strings } from "../../shared/i18n";
import {
  INK,
  PICTURE_TOOLS,
  PictureMarkups,
  arrowGeometry,
  boxBetween,
  comparePartner,
  drawMarks,
  escapeStep,
  finishedMark,
  fitZoom,
  fontSize,
  lineWidth,
  markedFileName,
  pinchedZoom,
  savedFileName,
  steppedIndex,
  toggledZoom,
  viewerKey,
  zoomedIn,
  zoomedOut,
  type PictureMark,
  type PictureTool,
  type Point,
  type Size,
} from "./pictureModel";
import "./viewer.css";

/** What the viewer shows: a message's pictures from one, or one video. */
export type MediaShown =
  | { kind: "pictures"; conversation: string; images: readonly HomeAttachment[]; index: number }
  | { kind: "video"; conversation: string; part: HomeAttachment; start: number };

/** Provides the page's opener to the attachments under it and draws the viewer over `children`'s
 * pane. `onSend`: Send in Chat's file goes to the message box (absent: no Send in Chat). */
export function MediaViewerHost({
  strings,
  onSend,
  onClosed,
  children,
}: {
  strings: Strings;
  onSend?(file: File): void;
  /** The viewer closed: the message box takes the keyboard back. */
  onClosed?(): void;
  children: ReactNode;
}) {
  const [shown, setShown] = useState<MediaShown>();
  const opener = useMemo<AttachmentOpener>(
    () => ({
      openImages: (conversation, images, index) => {
        if (images.length) setShown({ kind: "pictures", conversation, images, index });
      },
      openVideo: (conversation, part, video) => {
        const player = video ?? findPlayer(part.hash);
        const start = player?.currentTime ?? 0;
        player?.pause();
        setShown({ kind: "video", conversation, part, start });
      },
    }),
    [],
  );
  const close = () => {
    setShown(undefined);
    onClosed?.();
  };
  return (
    <AttachmentOpenContext.Provider value={opener}>
      {children}
      {shown?.kind === "pictures" && (
        <PictureViewer
          conversation={shown.conversation}
          images={shown.images}
          initialIndex={shown.index}
          strings={strings}
          onClose={close}
          {...(onSend ? { onSend } : {})}
        />
      )}
      {shown?.kind === "video" && (
        <VideoViewer
          conversation={shown.conversation}
          part={shown.part}
          start={shown.start}
          strings={strings}
          onClose={close}
        />
      )}
    </AttachmentOpenContext.Provider>
  );
}

/** The bubble's player of attachment `hash`, when it is on screen. */
function findPlayer(hash: string): HTMLVideoElement | undefined {
  return document.querySelector<HTMLVideoElement>(`video[data-attachment-video="${CSS.escape(hash)}"]`) ?? undefined;
}

/** The opener of the page (tests, the menus of a bubble). */
export function useAttachmentOpener(): AttachmentOpener | undefined {
  return useContext(AttachmentOpenContext);
}

/** The words being typed for a text mark: where (pixels) and where on screen (CSS px in the canvas). */
interface Typing {
  at: Point;
  left: number;
  top: number;
}

export function PictureViewer({
  conversation,
  images,
  initialIndex,
  strings,
  onClose,
  onSend,
}: {
  conversation: string;
  images: readonly HomeAttachment[];
  initialIndex: number;
  strings: Strings;
  onClose(): void;
  onSend?(file: File): void;
}) {
  const { t } = strings;
  const [index, setIndex] = useState(() => steppedIndex(initialIndex, 0, images.length));
  const [comparing, setComparing] = useState(false);
  const [tool, setTool] = useState<PictureTool>("move");
  const [markups] = useState(() => new PictureMarkups());
  const [, setMarksVersion] = useState(0);
  const [drawing, setDrawing] = useState<PictureMark>();
  const [typing, setTyping] = useState<Typing>();
  const [zoom, setZoom] = useState<number>();
  const [natural, setNatural] = useState<Size>();
  const [split, setSplit] = useState(0.5);
  const part = images[index]!;
  const partner = comparePartner(index, images.length);
  const pair = partner === undefined ? undefined : partner > index ? [index, partner] : [partner, index];
  const first = useImage(conversation, images[pair?.[0] ?? index]!, "original");
  const second = useImage(conversation, images[pair?.[1] ?? index]!, "original");
  const shown = useImage(conversation, part, "original");
  const root = useRef<HTMLElement | null>(null);
  const stage = useRef<HTMLDivElement | null>(null);
  const canvas = useRef<HTMLDivElement | null>(null);
  const textField = useRef<HTMLInputElement | null>(null);
  const marks = markups.of(index);
  const bumpMarks = () => setMarksVersion((version) => version + 1);

  // A new picture starts unmeasured and fits once its size is known.
  useLayoutEffect(() => {
    setNatural(part.width && part.height ? { width: part.width, height: part.height } : undefined);
    setZoom(undefined);
  }, [part]);
  const fitted = () => {
    const room = stage.current;
    return natural && room ? fitZoom(natural, { width: room.clientWidth, height: room.clientHeight }) : 1;
  };
  useLayoutEffect(() => {
    if (!natural || zoom !== undefined) return;
    const room = stage.current;
    setZoom(room ? fitZoom(natural, { width: room.clientWidth, height: room.clientHeight }) : 1);
  }, [natural, zoom]);
  useEffect(() => root.current?.focus(), []);

  // A pinch (a wheel with Control) zooms; the listener is not passive so the page does not zoom.
  useEffect(() => {
    const element = stage.current;
    if (!element) return;
    const wheel = (event: WheelEvent) => {
      if (!event.ctrlKey) return;
      event.preventDefault();
      setZoom((current) => pinchedZoom(current ?? 1, event.deltaY));
    };
    element.addEventListener("wheel", wheel, { passive: false });
    return () => element.removeEventListener("wheel", wheel);
  }, []);

  const endText = (commit: boolean) => {
    const field = textField.current;
    const at = typing;
    if (!at) return;
    setTyping(undefined);
    const words = field?.value.trim() ?? "";
    if (commit && words) {
      markups.add(index, { kind: "text", at: at.at, text: words });
      bumpMarks();
    }
    root.current?.focus();
  };

  const step = (by: number) => {
    const next = steppedIndex(index, by, images.length);
    if (next === index) return;
    endText(true);
    setIndex(next);
  };

  const exportPng = async (): Promise<Blob | undefined> => {
    endText(true);
    if (!shown.src || !natural) return undefined;
    return markedPng(shown.src, natural, markups.of(index));
  };

  const send = async () => {
    if (!onSend) return;
    const blob = await exportPng();
    if (!blob) return;
    onSend(new File([blob], markedFileName(part.name, Date.now()), { type: "image/png" }));
    onClose();
  };
  const copy = async () => {
    const blob = await exportPng();
    if (!blob || typeof ClipboardItem === "undefined") return;
    await navigator.clipboard?.write([new ClipboardItem({ "image/png": blob })]).catch(() => undefined);
  };
  const save = async () => {
    const blob = await exportPng();
    if (!blob) return;
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = savedFileName(part.name);
    anchor.click();
    // One shot: the download has read the bytes well before; the URL then ends.
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  };

  const run = (key: ReturnType<typeof viewerKey>): boolean => {
    switch (key) {
      case undefined:
        return false;
      case "escape": {
        const next = escapeStep({ typing: typing !== undefined, comparing });
        if (next === "text") endText(false);
        else if (next === "compare") setComparing(false);
        else onClose();
        return true;
      }
      case "left":
      case "right":
        step(key === "left" ? -1 : 1);
        return true;
      case "compare":
        setComparing((on) => !on && partner !== undefined);
        return true;
      case "undo":
        if (markups.undo(index)) bumpMarks();
        return true;
      case "zoomIn":
        setZoom((current) => zoomedIn(current ?? 1));
        return true;
      case "zoomOut":
        setZoom((current) => zoomedOut(current ?? 1));
        return true;
      case "fit":
        setZoom(fitted());
        return true;
      case "copy":
        void copy();
        return true;
    }
  };

  /** A point of the pointer in the picture's pixels. */
  const pixels = (event: { clientX: number; clientY: number }): Point => {
    const box = canvas.current?.getBoundingClientRect();
    if (!box || !natural || box.width <= 0 || box.height <= 0) return { x: 0, y: 0 };
    const clamp = (value: number, max: number) => Math.min(max, Math.max(0, value));
    return {
      x: (clamp(event.clientX - box.left, box.width) * natural.width) / box.width,
      y: (clamp(event.clientY - box.top, box.height) * natural.height) / box.height,
    };
  };

  const pointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    event.stopPropagation();
    const start = pixels(event);
    if (tool === "text") {
      endText(true);
      const box = canvas.current!.getBoundingClientRect();
      setTyping({ at: start, left: event.clientX - box.left, top: event.clientY - box.top });
      event.preventDefault();
      return;
    }
    const target = event.currentTarget;
    target.setPointerCapture?.(event.pointerId);
    if (tool === "move") {
      const view = stage.current;
      if (!view) return;
      const from = { x: event.clientX, y: event.clientY, left: view.scrollLeft, top: view.scrollTop };
      const move = (moved: PointerEvent) => {
        view.scrollLeft = from.left - (moved.clientX - from.x);
        view.scrollTop = from.top - (moved.clientY - from.y);
      };
      const up = () => {
        target.removeEventListener("pointermove", move);
        target.removeEventListener("pointerup", up);
        target.removeEventListener("pointercancel", up);
      };
      target.addEventListener("pointermove", move);
      target.addEventListener("pointerup", up);
      target.addEventListener("pointercancel", up);
      return;
    }
    let mark: PictureMark =
      tool === "arrow"
        ? { kind: "arrow", from: start, to: start }
        : tool === "box"
          ? boxBetween(start, start)
          : { kind: "pen", points: [start] };
    setDrawing(mark);
    const move = (moved: PointerEvent) => {
      const point = pixels(moved);
      mark =
        mark.kind === "arrow"
          ? { kind: "arrow", from: start, to: point }
          : mark.kind === "box"
            ? boxBetween(start, point)
            : mark.kind === "pen"
              ? { kind: "pen", points: [...mark.points, point] }
              : mark;
      setDrawing(mark);
    };
    const up = () => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", up);
      target.removeEventListener("pointercancel", up);
      setDrawing(undefined);
      const done = finishedMark(mark);
      if (done) {
        markups.add(index, done);
        bumpMarks();
      }
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", up);
    target.addEventListener("pointercancel", up);
  };

  const scale = zoom ?? 1;
  const size = natural ? { width: natural.width * scale, height: natural.height * scale } : undefined;
  const failed = shown.failed && !shown.src;
  const tools: { tool: PictureTool; label: string; icon: ReactNode }[] = PICTURE_TOOLS.map((entry) => ({
    tool: entry,
    label: t(`home.picture.tool.${entry}`),
    icon: <ToolGlyph tool={entry} />,
  }));
  return (
    <KeyboardScope
      className="mv-scope"
      handleKeyDown={(event) => {
        const inField = event.target === textField.current;
        // The words being typed take every key but Escape.
        if (inField && event.key !== "Escape") {
          if (event.key === "Enter") {
            event.preventDefault();
            endText(true);
          }
          return;
        }
        if (run(viewerKey(event))) {
          event.preventDefault();
          event.stopPropagation();
        }
      }}
    >
      <section ref={root} className="mv-viewer" aria-label={t("home.picture.viewer")} tabIndex={-1}>
        <header className="mv-top">
          <span className="mv-title">{part.name || t("home.table.picture")}</span>
          {images.length > 1 && (
            <span className="mv-counter">
              {strings.format("home.picture.counter", String(index + 1), String(images.length))}
            </span>
          )}
          <button type="button" className="mv-close" aria-label={t("home.picture.close")} onClick={onClose}>
            <HomeIcon name="close" />
          </button>
        </header>
        {/* The space around the picture: a press there closes the viewer, as the native one. */}
        <div
          ref={stage}
          className={`mv-stage${comparing ? " comparing" : ""}`}
          onPointerDown={(event) => {
            if (event.target === event.currentTarget || (event.target as Element).classList.contains("mv-center"))
              onClose();
          }}
        >
          {comparing && pair ? (
            <Compare
              first={first.src}
              second={second.src}
              firstTitle={images[pair[0]]!.name}
              secondTitle={images[pair[1]]!.name}
              split={split}
              onSplit={setSplit}
            />
          ) : (
            <div className="mv-center">
              {size && (
                <div
                  ref={canvas}
                  className={`mv-canvas tool-${tool}`}
                  style={{ width: size.width, height: size.height }}
                  onPointerDown={pointerDown}
                  onDoubleClick={() => tool === "move" && setZoom(toggledZoom(scale, fitted()))}
                >
                  {shown.src && <img src={shown.src} alt={part.name} draggable={false} />}
                  <MarksLayer marks={drawing ? [...marks, drawing] : marks} size={natural!} />
                  {typing && (
                    <input
                      ref={textField}
                      className="mv-text-field"
                      style={{ left: typing.left, top: typing.top, color: INK }}
                      placeholder={t("home.picture.textPlaceholder")}
                      aria-label={t("home.picture.tool.text")}
                      // oxlint-disable-next-line jsx-a11y/no-autofocus -- the words go where the person just clicked.
                      autoFocus
                      onBlur={() => endText(true)}
                    />
                  )}
                </div>
              )}
              {!size && shown.src && (
                <img
                  className="mv-measure"
                  src={shown.src}
                  alt=""
                  onLoad={(event) =>
                    setNatural({
                      width: event.currentTarget.naturalWidth || 1,
                      height: event.currentTarget.naturalHeight || 1,
                    })
                  }
                />
              )}
              {failed && (
                <p className="mv-status" role="alert">
                  {t("home.picture.loadFailed")}
                </p>
              )}
              {!failed && !shown.src && <output className="mv-status" aria-label={t("home.picture.loading")} />}
            </div>
          )}
        </div>
        {images.length > 1 && (
          <>
            <button
              type="button"
              className="mv-step prev"
              aria-label={t("home.picture.previous")}
              disabled={index === 0}
              onClick={() => step(-1)}
            >
              <HomeIcon name="chevronLeft" />
            </button>
            <button
              type="button"
              className="mv-step next"
              aria-label={t("home.picture.next")}
              disabled={index === images.length - 1}
              onClick={() => step(1)}
            >
              <HomeIcon name="chevronRight" />
            </button>
          </>
        )}
        <div className="mv-bar" role="toolbar" aria-label={t("home.picture.viewer")}>
          <div className="mv-tools">
            {tools.map((entry) => (
              <button
                key={entry.tool}
                type="button"
                className={`mv-tool${tool === entry.tool ? " on" : ""}`}
                aria-label={entry.label}
                aria-pressed={tool === entry.tool}
                title={entry.label}
                disabled={comparing}
                onClick={() => {
                  endText(true);
                  setTool(entry.tool);
                }}
              >
                {entry.icon}
              </button>
            ))}
          </div>
          <BarButton label={t("home.picture.undo")} disabled={marks.length === 0} onClick={() => run("undo")}>
            <Icon name="action.undo" size={14} />
          </BarButton>
          <BarButton
            label={t("home.picture.compare")}
            pressed={comparing}
            disabled={partner === undefined}
            onClick={() => run("compare")}
          >
            <Icon name="diff.split" size={14} />
          </BarButton>
          <BarButton label={t("home.picture.copy")} disabled={!shown.src} onClick={() => void copy()}>
            <Icon name="action.copy" size={14} />
          </BarButton>
          <BarButton label={t("home.picture.save")} disabled={!shown.src} onClick={() => void save()}>
            <Icon name="action.download" size={14} />
          </BarButton>
          {onSend && (
            <BarButton label={t("home.picture.reply")} disabled={!shown.src} onClick={() => void send()}>
              <HomeIcon name="reply" size={16} />
            </BarButton>
          )}
        </div>
      </section>
    </KeyboardScope>
  );
}

function BarButton({
  label,
  disabled,
  pressed,
  onClick,
  children,
}: {
  label: string;
  disabled?: boolean;
  pressed?: boolean;
  onClick(): void;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      className={`mv-tool${pressed ? " on" : ""}`}
      aria-label={label}
      title={label}
      disabled={disabled}
      {...(pressed !== undefined ? { "aria-pressed": pressed } : {})}
      onClick={onClick}
    >
      {children}
    </button>
  );
}

/** The marks over the picture, in its pixels (the SVG scales with the shown size). */
function MarksLayer({ marks, size }: { marks: readonly PictureMark[]; size: Size }) {
  const width = lineWidth(size);
  const font = fontSize(size);
  return (
    <svg
      className="mv-marks"
      viewBox={`0 0 ${size.width} ${size.height}`}
      preserveAspectRatio="none"
      aria-hidden
      stroke={INK}
      fill="none"
      strokeWidth={width}
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {marks.map((mark, at) => {
        switch (mark.kind) {
          case "box":
            return <rect key={at} x={mark.x} y={mark.y} width={mark.width} height={mark.height} />;
          case "pen":
            return <polyline key={at} points={mark.points.map((p) => `${p.x},${p.y}`).join(" ")} />;
          case "arrow": {
            const shape = arrowGeometry(mark.from, mark.to, width);
            if (!shape) return null;
            return (
              <g key={at}>
                <line x1={mark.from.x} y1={mark.from.y} x2={shape.base.x} y2={shape.base.y} />
                <polygon
                  fill={INK}
                  stroke="none"
                  points={`${mark.to.x},${mark.to.y} ${shape.left.x},${shape.left.y} ${shape.right.x},${shape.right.y}`}
                />
              </g>
            );
          }
          case "text":
            return (
              <text
                key={at}
                x={mark.at.x}
                y={mark.at.y}
                dominantBaseline="hanging"
                fontSize={font}
                fontWeight="bold"
                fill={INK}
                stroke="white"
                strokeWidth={font / 3}
                paintOrder="stroke"
              >
                {mark.text}
              </text>
            );
        }
      })}
    </svg>
  );
}

/** Two pictures over each other, the first left of the slider (HomePictureCompare). */
function Compare({
  first,
  second,
  firstTitle,
  secondTitle,
  split,
  onSplit,
}: {
  first?: string;
  second?: string;
  firstTitle: string;
  secondTitle: string;
  split: number;
  onSplit(split: number): void;
}) {
  const box = useRef<HTMLDivElement | null>(null);
  const follow = (event: { clientX: number }) => {
    const frame = box.current?.getBoundingClientRect();
    if (frame && frame.width > 0) onSplit(Math.min(1, Math.max(0, (event.clientX - frame.left) / frame.width)));
  };
  const percent = `${split * 100}%`;
  return (
    <div
      ref={box}
      className="mv-compare"
      onPointerDown={(event) => {
        event.stopPropagation();
        event.currentTarget.setPointerCapture?.(event.pointerId);
        follow(event);
      }}
      onPointerMove={(event) => event.buttons === 1 && follow(event)}
    >
      {second && <img src={second} alt={secondTitle} draggable={false} />}
      {first && (
        <img
          className="first"
          src={first}
          alt={firstTitle}
          draggable={false}
          style={{ clipPath: `inset(0 calc(100% - ${percent}) 0 0)` }}
        />
      )}
      <span className="mv-split" style={{ left: percent }} aria-hidden />
      <span className="mv-pill lead">{firstTitle}</span>
      <span className="mv-pill trail">{secondTitle}</span>
    </div>
  );
}

function ToolGlyph({ tool }: { tool: PictureTool }) {
  const path: Record<PictureTool, ReactNode> = {
    move: (
      <path d="M8 1.5v13M1.5 8h13M8 1.5 6 3.5M8 1.5l2 2M8 14.5l-2-2M8 14.5l2-2M1.5 8l2-2M1.5 8l2 2M14.5 8l-2-2M14.5 8l-2 2" />
    ),
    arrow: <path d="M3 13 13 3M7 3h6v6" />,
    box: <rect x="2.5" y="3.5" width="11" height="9" rx="1" />,
    pen: <path d="M2 11c2-4 4 2 6-2s4-2 6-5" />,
    text: <path d="M3 3.5h10M8 3.5v9" />,
  };
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden>
      {path[tool]}
    </svg>
  );
}

/** The picture `src` with `marks` drawn into its own pixels, as a PNG. A picture read through a
 * link is fetched as bytes first, so the canvas stays readable. */
export async function markedPng(src: string, size: Size, marks: readonly PictureMark[]): Promise<Blob | undefined> {
  try {
    const bytes = await fetch(src).then((response) => response.blob());
    const bitmap = await createImageBitmap(bytes);
    const canvas = document.createElement("canvas");
    canvas.width = bitmap.width || size.width;
    canvas.height = bitmap.height || size.height;
    const ctx = canvas.getContext("2d");
    if (!ctx) return undefined;
    ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    drawMarks(ctx, marks, { width: canvas.width, height: canvas.height });
    bitmap.close();
    return await new Promise<Blob | undefined>((resolve) =>
      canvas.toBlob((blob) => resolve(blob ?? undefined), "image/png"),
    );
  } catch {
    return undefined;
  }
}

/** View Larger: the video over the pane, from where its bubble was (HomeVideoViewer). */
export function VideoViewer({
  conversation,
  part,
  start,
  strings,
  onClose,
}: {
  conversation: string;
  part: HomeAttachment;
  start: number;
  strings: Strings;
  onClose(): void;
}) {
  const service = useContext(AttachmentContext);
  const [src, setSrc] = useState<string>();
  const root = useRef<HTMLElement | null>(null);
  useEffect(() => {
    root.current?.focus();
    if (!service) return;
    let live = true;
    service.url(conversation, part.hash, "original", part.name).then(
      (url) => live && setSrc(url),
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [service, conversation, part.hash, part.name]);
  const label = strings.t("home.video.closeViewer");
  return (
    <KeyboardScope
      className="mv-scope"
      handleKeyDown={(event) => {
        if (event.key !== "Escape") return;
        event.preventDefault();
        event.stopPropagation();
        onClose();
      }}
    >
      <section ref={root} className="mv-viewer mv-video" aria-label={strings.t("home.video.viewLarger")} tabIndex={-1}>
        <div
          className="mv-stage"
          onPointerDown={(event) => {
            if (event.target === event.currentTarget) onClose();
          }}
        >
          {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- a user's attached file; it has no caption track. */}
          <video
            src={src}
            controls
            autoPlay
            playsInline
            aria-label={part.name}
            onLoadedMetadata={(event) => {
              if (start > 0) event.currentTarget.currentTime = start;
            }}
          />
        </div>
        <button type="button" className="mv-close floating" aria-label={label} title={label} onClick={onClose}>
          <HomeIcon name="close" />
        </button>
      </section>
    </KeyboardScope>
  );
}

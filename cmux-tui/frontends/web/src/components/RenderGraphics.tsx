import {
  useCallback,
  useMemo,
  useRef,
  useSyncExternalStore,
  type CSSProperties,
  type ReactNode,
} from "react";
import type { RenderGraphicImage } from "cmux/browser";
import { useDecodedRenderGraphicImages } from "../hooks/useDecodedRenderGraphicImages";
import type { RenderGraphicsModel } from "../lib/renderModel";
import {
  RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP,
  RENDER_GRAPHIC_CANVAS_COUNT_CAP,
  RENDER_GRAPHIC_DECODED_BYTE_CAP,
  renderGraphicImageKey,
  renderGraphicRgbaByteLength,
  resolveRenderGraphicPlacement,
  type DecodedRenderGraphicImage,
  type ResolvedRenderGraphicPlacement,
} from "../lib/renderGraphics";

interface RenderGraphicsProps {
  backgroundChildren?: ReactNode;
  children: ReactNode;
  graphics?: RenderGraphicsModel;
}

interface RenderGraphicCanvasProps {
  decoded: DecodedRenderGraphicImage;
  placement: ResolvedRenderGraphicPlacement;
}

interface RenderGraphicCandidate {
  image: RenderGraphicImage;
  placement: ResolvedRenderGraphicPlacement;
  order: number;
  decodedBytes: number;
}

interface GraphicsSelection {
  placements: ReadonlySet<RenderGraphicCandidate>;
  images: ReadonlySet<string>;
}

interface RenderedPlacement extends RenderGraphicCandidate {
  decoded: DecodedRenderGraphicImage;
}

const EMPTY_IMAGES: readonly RenderGraphicImage[] = [];
const EMPTY_SELECTION: GraphicsSelection = {
  placements: new Set(),
  images: new Set(),
};

function compareCandidates(
  left: RenderGraphicCandidate,
  right: RenderGraphicCandidate,
): number {
  return left.placement.z - right.placement.z || left.order - right.order;
}

function heapPush<T>(
  heap: T[],
  value: T,
  comparePriority: (left: T, right: T) => number,
): void {
  heap.push(value);
  let index = heap.length - 1;
  while (index > 0) {
    const parent = Math.floor((index - 1) / 2);
    if (comparePriority(heap[parent], heap[index]) >= 0) break;
    [heap[parent], heap[index]] = [heap[index], heap[parent]];
    index = parent;
  }
}

function heapPop<T>(
  heap: T[],
  comparePriority: (left: T, right: T) => number,
): T | undefined {
  const root = heap[0];
  const tail = heap.pop();
  if (tail === undefined || heap.length === 0) return root;
  heap[0] = tail;
  let index = 0;
  while (true) {
    const left = index * 2 + 1;
    const right = left + 1;
    let next = index;
    if (left < heap.length && comparePriority(heap[left], heap[next]) > 0) next = left;
    if (right < heap.length && comparePriority(heap[right], heap[next]) > 0) next = right;
    if (next === index) break;
    [heap[index], heap[next]] = [heap[next], heap[index]];
    index = next;
  }
  return root;
}

function selectTopCandidates(
  candidates: readonly RenderGraphicCandidate[],
): readonly RenderGraphicCandidate[] {
  const worstFirst: RenderGraphicCandidate[] = [];
  const compareWorst = (
    left: RenderGraphicCandidate,
    right: RenderGraphicCandidate,
  ) => -compareCandidates(left, right);
  for (const candidate of candidates) {
    if (worstFirst.length < RENDER_GRAPHIC_CANVAS_COUNT_CAP) {
      heapPush(worstFirst, candidate, compareWorst);
      continue;
    }
    if (compareCandidates(candidate, worstFirst[0]) <= 0) continue;
    worstFirst[0] = candidate;
    let index = 0;
    while (true) {
      const left = index * 2 + 1;
      const right = left + 1;
      let next = index;
      if (left < worstFirst.length
        && compareWorst(worstFirst[left], worstFirst[next]) > 0) next = left;
      if (right < worstFirst.length
        && compareWorst(worstFirst[right], worstFirst[next]) > 0) next = right;
      if (next === index) break;
      [worstFirst[index], worstFirst[next]] = [worstFirst[next], worstFirst[index]];
      index = next;
    }
  }
  return worstFirst.sort((left, right) => -compareCandidates(left, right));
}

interface OwnerCandidates {
  order: number;
  values: readonly RenderGraphicCandidate[];
}

interface GlobalCandidateCursor {
  owner: symbol;
  ownerOrder: number;
  candidate: RenderGraphicCandidate;
  index: number;
}

class GraphicsBudgetRegistry {
  private readonly candidates = new Map<symbol, OwnerCandidates>();
  private readonly selections = new Map<symbol, GraphicsSelection>();
  private readonly listeners = new Map<symbol, Set<() => void>>();
  private readonly revisions = new Map<symbol, number>();
  private readonly pendingRemovals = new Map<symbol, symbol>();
  private nextOwnerOrder = 0;

  subscribe(owner: symbol, listener: () => void): () => void {
    let listeners = this.listeners.get(owner);
    if (listeners === undefined) {
      listeners = new Set();
      this.listeners.set(owner, listeners);
    }
    listeners.add(listener);
    return () => {
      listeners?.delete(listener);
      if (listeners?.size === 0) this.listeners.delete(owner);
    };
  }

  snapshot(owner: symbol): number {
    return this.revisions.get(owner) ?? 0;
  }

  selected(owner: symbol): GraphicsSelection {
    return this.selections.get(owner) ?? EMPTY_SELECTION;
  }

  update(owner: symbol, candidates: readonly RenderGraphicCandidate[]): void {
    this.pendingRemovals.delete(owner);
    const current = this.candidates.get(owner);
    this.candidates.set(owner, {
      order: current?.order ?? this.nextOwnerOrder++,
      values: candidates.slice(0, RENDER_GRAPHIC_CANVAS_COUNT_CAP),
    });
    this.recalculate();
  }

  scheduleRemove(owner: symbol): void {
    const token = Symbol("graphics-budget-removal");
    this.pendingRemovals.set(owner, token);
    queueMicrotask(() => {
      if (this.pendingRemovals.get(owner) !== token) return;
      this.pendingRemovals.delete(owner);
      if (!this.candidates.delete(owner)) return;
      this.selections.delete(owner);
      this.revisions.delete(owner);
      this.recalculate();
    });
  }

  private recalculate(): void {
    const nextPlacements = new Map<symbol, Set<RenderGraphicCandidate>>();
    const nextImages = new Map<symbol, Set<string>>();
    for (const owner of this.candidates.keys()) {
      nextPlacements.set(owner, new Set());
      nextImages.set(owner, new Set());
    }
    const compareGlobal = (
      left: GlobalCandidateCursor,
      right: GlobalCandidateCursor,
    ) => compareCandidates(left.candidate, right.candidate)
      || right.ownerOrder - left.ownerOrder;
    const cursors: GlobalCandidateCursor[] = [];
    for (const [owner, state] of this.candidates) {
      const candidate = state.values[0];
      if (candidate !== undefined) {
        heapPush(cursors, {
          owner,
          ownerOrder: state.order,
          candidate,
          index: 0,
        }, compareGlobal);
      }
    }
    let admitted = 0;
    let backingBytes = 0;
    let decodedBytes = 0;
    while (cursors.length > 0 && admitted < RENDER_GRAPHIC_CANVAS_COUNT_CAP) {
      const { owner, ownerOrder, candidate, index } = heapPop(cursors, compareGlobal)!;
      const nextIndex = index + 1;
      const nextCandidate = this.candidates.get(owner)?.values[nextIndex];
      if (nextCandidate !== undefined) {
        heapPush(cursors, {
          owner,
          ownerOrder,
          candidate: nextCandidate,
          index: nextIndex,
        }, compareGlobal);
      }
      if (candidate.placement.backingBytes
        > RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP - backingBytes) continue;
      const images = nextImages.get(owner)!;
      const imageKey = renderGraphicImageKey(candidate.image);
      if (!images.has(imageKey)
        && candidate.decodedBytes > RENDER_GRAPHIC_DECODED_BYTE_CAP - decodedBytes) continue;
      nextPlacements.get(owner)!.add(candidate);
      if (!images.has(imageKey)) {
        images.add(imageKey);
        decodedBytes += candidate.decodedBytes;
      }
      backingBytes += candidate.placement.backingBytes;
      admitted += 1;
    }

    const next = new Map<symbol, GraphicsSelection>();
    for (const [owner, placements] of nextPlacements) {
      next.set(owner, { placements, images: nextImages.get(owner)! });
    }
    for (const [owner, selection] of next) {
      const previous = this.selections.get(owner);
      const changed = previous === undefined
        || previous.placements.size !== selection.placements.size
        || previous.images.size !== selection.images.size
        || [...selection.placements].some((candidate) =>
          !previous.placements.has(candidate)
        )
        || [...selection.images].some((imageKey) => !previous.images.has(imageKey));
      if (!changed) continue;
      this.selections.set(owner, selection);
      this.revisions.set(owner, (this.revisions.get(owner) ?? 0) + 1);
      for (const listener of this.listeners.get(owner) ?? []) listener();
    }
  }
}

const graphicsBudget = new GraphicsBudgetRegistry();

function RenderGraphicCanvas({ decoded, placement }: RenderGraphicCanvasProps) {
  const canvasRef = useCallback((canvas: HTMLCanvasElement | null) => {
    if (canvas === null || typeof ImageData === "undefined") return;
    const context = canvas.getContext("2d");
    if (context === null) return;
    const pixels = new ImageData(
      decoded.pixels,
      decoded.image.width,
      decoded.image.height,
    );
    const source = placement.source;
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.putImageData(
      pixels,
      -source.x,
      -source.y,
      source.x,
      source.y,
      source.width,
      source.height,
    );
    return () => {
      canvas.width = 0;
      canvas.height = 0;
    };
  }, [decoded, placement]);

  return (
    <canvas
      aria-hidden="true"
      className="render-graphic-placement"
      data-graphic-placement={placement.key}
      height={placement.source.height}
      ref={canvasRef}
      style={placement.style satisfies CSSProperties}
      width={placement.source.width}
    />
  );
}

export function RenderGraphics({
  backgroundChildren,
  children,
  graphics,
}: RenderGraphicsProps) {
  const owner = useRef(Symbol("render-graphics")).current;
  const images = graphics?.images ?? EMPTY_IMAGES;
  const imageById = useMemo(
    () => new Map(images.map((image) => [image.id, image])),
    [images],
  );
  const candidates = useMemo(() => {
    const rendered: RenderGraphicCandidate[] = [];
    for (const [order, candidate] of (graphics?.placements ?? []).entries()) {
      const image = imageById.get(candidate.image_id);
      if (image === undefined) continue;
      const decodedBytes = renderGraphicRgbaByteLength(image);
      if (decodedBytes === null) continue;
      const placement = resolveRenderGraphicPlacement(image, candidate);
      if (placement !== null) rendered.push({ image, placement, order, decodedBytes });
    }
    return selectTopCandidates(rendered);
  }, [graphics?.placements, imageById]);
  const subscribeBudget = useCallback(
    (listener: () => void) => graphicsBudget.subscribe(owner, listener),
    [owner],
  );
  const budgetSnapshot = useCallback(
    () => graphicsBudget.snapshot(owner),
    [owner],
  );
  const budgetRevision = useSyncExternalStore(
    subscribeBudget,
    budgetSnapshot,
    budgetSnapshot,
  );
  const selected = graphicsBudget.selected(owner);
  const admittedImages = useMemo(
    () => images.filter((image) => selected.images.has(renderGraphicImageKey(image))),
    [budgetRevision, images, selected],
  );
  const decodedImages = useDecodedRenderGraphicImages(admittedImages);
  const placements = useMemo(() => {
    const rendered = candidates
      .filter((candidate) => selected.placements.has(candidate))
      .flatMap((candidate): RenderedPlacement[] => {
        const decoded = decodedImages.get(candidate.image.id);
        return decoded === undefined ? [] : [{ ...candidate, decoded }];
      })
      .sort((left, right) =>
        left.placement.z - right.placement.z || left.order - right.order
      );
    const belowBackground: RenderedPlacement[] = [];
    const below: RenderedPlacement[] = [];
    const above: RenderedPlacement[] = [];
    for (const candidate of rendered) {
      if (candidate.placement.layer === "belowBackground") {
        belowBackground.push(candidate);
      } else if (candidate.placement.layer === "below") {
        below.push(candidate);
      } else {
        above.push(candidate);
      }
    }
    return { belowBackground, below, above };
  }, [budgetRevision, candidates, decodedImages, selected]);
  const registerBudget = useCallback((element: HTMLDivElement | null) => {
    if (element === null) return;
    graphicsBudget.update(owner, candidates);
    return () => graphicsBudget.scheduleRemove(owner);
  }, [candidates, owner]);

  return (
    <>
      <div
        aria-hidden="true"
        className="render-graphics-layer render-graphics-below-background"
        ref={registerBudget}
      >
        {placements.belowBackground.map(({ decoded, placement, order }) => (
          <RenderGraphicCanvas
            decoded={decoded}
            key={`${placement.key}:${order}`}
            placement={placement}
          />
        ))}
      </div>
      {backgroundChildren}
      <div
        aria-hidden="true"
        className="render-graphics-layer render-graphics-below"
      >
        {placements.below.map(({ decoded, placement, order }) => (
          <RenderGraphicCanvas
            decoded={decoded}
            key={`${placement.key}:${order}`}
            placement={placement}
          />
        ))}
      </div>
      {children}
      <div aria-hidden="true" className="render-graphics-layer render-graphics-above">
        {placements.above.map(({ decoded, placement, order }) => (
          <RenderGraphicCanvas
            decoded={decoded}
            key={`${placement.key}:${order}`}
            placement={placement}
          />
        ))}
      </div>
    </>
  );
}

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type CSSProperties,
  type ReactNode,
} from "react";
import type { RenderGraphicImage, RenderGraphicPlacement } from "cmux/raw";
import { useDecodedRenderGraphicImages } from "../hooks/useDecodedRenderGraphicImages";
import type { RenderGraphicsModel } from "../lib/renderModel";
import {
  planRenderGraphicPlacement,
  RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP,
  RENDER_GRAPHIC_CANVAS_COUNT_CAP,
  RENDER_GRAPHIC_DECODED_BYTE_CAP,
  renderGraphicRgbaByteLength,
  resolveRenderGraphicPlacementPlan,
  type DecodedRenderGraphicImage,
  type RenderGraphicPlacementPlan,
  type ResolvedRenderGraphicPlacement,
} from "../lib/renderGraphics";
import { RenderGraphicsDecodeScheduler } from "../lib/renderGraphicsDecodeScheduler";

interface RenderGraphicsProps {
  backgroundChildren?: ReactNode;
  children: ReactNode;
  graphics?: RenderGraphicsModel;
  plainChildren?: ReactNode;
}

interface RenderGraphicCanvasProps {
  decoded: DecodedRenderGraphicImage;
  placement: ResolvedRenderGraphicPlacement;
}

interface CandidatePriority {
  z: number;
  order: number;
}

interface RenderGraphicCandidate extends CandidatePriority {
  imageId: number;
  placement: RenderGraphicPlacementPlan;
  decodedBytes: number;
}

interface GraphicsSelection {
  placements: ReadonlySet<RenderGraphicCandidate>;
  images: ReadonlySet<number>;
}

interface RenderedPlacement {
  decoded: DecodedRenderGraphicImage;
  order: number;
  placement: ResolvedRenderGraphicPlacement;
}

interface ImageAdmissionMetadata {
  decodedBytes: number;
  id: number;
  width: number;
  height: number;
}

const EMPTY_IMAGES: readonly RenderGraphicImage[] = [];
const EMPTY_PLACEMENTS: readonly RenderGraphicPlacement[] = [];
const EMPTY_SELECTION: GraphicsSelection = {
  placements: new Set(),
  images: new Set(),
};

function compareCandidates(
  left: CandidatePriority,
  right: CandidatePriority,
): number {
  return compareCandidateValues(left.z, left.order, right.z, right.order);
}

function compareCandidateValues(
  leftZ: number,
  leftOrder: number,
  rightZ: number,
  rightOrder: number,
): number {
  return leftZ - rightZ || leftOrder - rightOrder;
}

function candidateBackingBytesLowerBound(placement: RenderGraphicPlacement): number {
  const width = placement.source_width;
  const height = placement.source_height;
  if (!Number.isSafeInteger(width) || width <= 0
    || !Number.isSafeInteger(height) || height <= 0) return 0;
  const pixels = width * height;
  const bytes = pixels * 4;
  // Every valid placement plan uses this exact byte count. Returning zero for
  // malformed or overflowing dimensions makes suffix pruning conservative.
  return Number.isSafeInteger(pixels) && Number.isSafeInteger(bytes) ? bytes : 0;
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

class RenderGraphicCandidateSource {
  private readonly candidateCache:
    (RenderGraphicCandidate | null | undefined)[];
  private readonly minimumBackingBytes: number[];
  private readonly placementIndexes: number[];

  constructor(
    private readonly placements: readonly RenderGraphicPlacement[],
    private readonly images: ReadonlyMap<number, ImageAdmissionMetadata>,
  ) {
    this.placementIndexes = [];
    for (const [order, placement] of placements.entries()) {
      if (!placement.viewport_visible || !Number.isSafeInteger(placement.z)
        || !images.has(placement.image_id)) continue;
      this.placementIndexes.push(order);
    }
    this.placementIndexes.sort((left, right) =>
      -compareCandidateValues(
        placements[left]!.z,
        left,
        placements[right]!.z,
        right,
      )
    );
    this.candidateCache = new Array(this.placementIndexes.length);

    // Store only bounded protocol indexes, not geometry plans. The one-time
    // ordering avoids rescanning all placements for each 512-candidate page,
    // while plans remain lazy for candidates the global budget considers.
    this.minimumBackingBytes = new Array(this.placementIndexes.length);
    let minimum = Number.POSITIVE_INFINITY;
    for (let position = this.placementIndexes.length - 1; position >= 0; position -= 1) {
      const placement = placements[this.placementIndexes[position]!]!;
      minimum = Math.min(minimum, candidateBackingBytesLowerBound(placement));
      this.minimumBackingBytes[position] = minimum;
    }
  }

  canFitBackingFrom(position: number, availableBytes: number): boolean {
    return (this.minimumBackingBytes[position] ?? Number.POSITIVE_INFINITY) <= availableBytes;
  }

  candidateFrom(
    startPosition: number,
    rejectedImages: ReadonlySet<number>,
  ):
    | { candidate: RenderGraphicCandidate; nextPosition: number }
    | undefined {
    for (let position = startPosition; position < this.placementIndexes.length; position += 1) {
      const order = this.placementIndexes[position]!;
      const rawPlacement = this.placements[order]!;
      const image = this.images.get(rawPlacement.image_id);
      if (image === undefined) continue;
      if (rejectedImages.has(image.id)) continue;
      let candidate = this.candidateCache[position];
      if (candidate === undefined) {
        const placement = planRenderGraphicPlacement(image, rawPlacement);
        candidate = placement === null
          ? null
          : {
            imageId: image.id,
            placement,
            order,
            z: rawPlacement.z,
            decodedBytes: image.decodedBytes,
          };
        this.candidateCache[position] = candidate;
      }
      if (candidate === null) continue;
      return {
        candidate,
        nextPosition: position + 1,
      };
    }
    return undefined;
  }
}

interface OwnerCandidates {
  order: number;
  source: RenderGraphicCandidateSource;
}

interface GlobalCandidateCursor {
  owner: symbol;
  ownerOrder: number;
  candidate: RenderGraphicCandidate;
  nextPosition: number;
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

  update(owner: symbol, source: RenderGraphicCandidateSource): void {
    this.pendingRemovals.delete(owner);
    const current = this.candidates.get(owner);
    this.candidates.set(owner, {
      order: current?.order ?? this.nextOwnerOrder++,
      source,
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
    const nextImages = new Map<symbol, Set<number>>();
    const rejectedImages = new Map<symbol, Set<number>>();
    for (const owner of this.candidates.keys()) {
      nextPlacements.set(owner, new Set());
      nextImages.set(owner, new Set());
      rejectedImages.set(owner, new Set());
    }
    const compareGlobal = (
      left: GlobalCandidateCursor,
      right: GlobalCandidateCursor,
    ) => compareCandidates(left.candidate, right.candidate)
      || right.ownerOrder - left.ownerOrder;
    const cursors: GlobalCandidateCursor[] = [];
    for (const [owner, state] of this.candidates) {
      const next = state.source.candidateFrom(0, rejectedImages.get(owner)!);
      if (next !== undefined) {
        heapPush(cursors, {
          owner,
          ownerOrder: state.order,
          candidate: next.candidate,
          nextPosition: next.nextPosition,
        }, compareGlobal);
      }
    }
    let admitted = 0;
    let backingBytes = 0;
    let decodedBytes = 0;
    while (cursors.length > 0 && admitted < RENDER_GRAPHIC_CANVAS_COUNT_CAP) {
      const { owner, ownerOrder, candidate, nextPosition } = heapPop(cursors, compareGlobal)!;
      if (candidate.placement.backingBytes
        <= RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP - backingBytes) {
        const images = nextImages.get(owner)!;
        const imageId = candidate.imageId;
        if (images.has(imageId)
          || candidate.decodedBytes <= RENDER_GRAPHIC_DECODED_BYTE_CAP - decodedBytes) {
          nextPlacements.get(owner)!.add(candidate);
          if (!images.has(imageId)) {
            images.add(imageId);
            decodedBytes += candidate.decodedBytes;
          }
          backingBytes += candidate.placement.backingBytes;
          admitted += 1;
        } else {
          rejectedImages.get(owner)!.add(imageId);
        }
      }
      if (admitted >= RENDER_GRAPHIC_CANVAS_COUNT_CAP) continue;
      const source = this.candidates.get(owner)?.source;
      if (source === undefined
        || !source.canFitBackingFrom(
          nextPosition,
          RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP - backingBytes,
        )) continue;
      const next = source.candidateFrom(nextPosition, rejectedImages.get(owner)!);
      if (next !== undefined) {
        heapPush(cursors, {
          owner,
          ownerOrder,
          candidate: next.candidate,
          nextPosition: next.nextPosition,
        }, compareGlobal);
      }
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
        || [...selection.images].some((imageId) => !previous.images.has(imageId));
      if (!changed) continue;
      this.selections.set(owner, selection);
      this.revisions.set(owner, (this.revisions.get(owner) ?? 0) + 1);
      for (const listener of this.listeners.get(owner) ?? []) listener();
    }
  }
}

interface RenderGraphicsResources {
  budget: GraphicsBudgetRegistry;
  decoder: RenderGraphicsDecodeScheduler;
  modelBudget: object;
}

const GraphicsResourcesContext = createContext<RenderGraphicsResources | null>(null);
const defaultModelBudget = {};

function useDecoderLifetime(decoder: RenderGraphicsDecodeScheduler): void {
  useEffect(() => {
    decoder.retain();
    return () => decoder.scheduleDispose();
  }, [decoder]);
}

export function RenderGraphicsBudgetProvider({ children }: { children: ReactNode }) {
  const [resources] = useState<RenderGraphicsResources>(() => ({
    budget: new GraphicsBudgetRegistry(),
    decoder: new RenderGraphicsDecodeScheduler(),
    modelBudget: {},
  }));
  useDecoderLifetime(resources.decoder);
  return (
    <GraphicsResourcesContext.Provider value={resources}>
      {children}
    </GraphicsResourcesContext.Provider>
  );
}

function useGraphicsResources(): RenderGraphicsResources {
  const resources = useContext(GraphicsResourcesContext);
  if (resources === null) {
    throw new Error("RenderGraphics requires RenderGraphicsBudgetProvider");
  }
  return resources;
}

export function useRenderGraphicsModelBudget(): object {
  return useContext(GraphicsResourcesContext)?.modelBudget ?? defaultModelBudget;
}

function useImageAdmissionMetadata(
  images: readonly RenderGraphicImage[],
): ReadonlyMap<number, ImageAdmissionMetadata> {
  const previous = useRef<ReadonlyMap<number, ImageAdmissionMetadata>>(new Map());
  return useMemo(() => {
    const metadata = new Map<number, ImageAdmissionMetadata>();
    for (const image of images) {
      const decodedBytes = renderGraphicRgbaByteLength(image);
      if (decodedBytes !== null) {
        metadata.set(image.id, {
          decodedBytes,
          id: image.id,
          width: image.width,
          height: image.height,
        });
      }
    }
    const retained = previous.current;
    let unchanged = retained.size === metadata.size;
    if (unchanged) {
      for (const [id, candidate] of metadata) {
        const current = retained.get(id);
        if (current === undefined
          || current.decodedBytes !== candidate.decodedBytes
          || current.width !== candidate.width
          || current.height !== candidate.height) {
          unchanged = false;
          break;
        }
      }
    }
    if (unchanged) return retained;
    previous.current = metadata;
    return metadata;
  }, [images]);
}

function RenderGraphicCanvas({ decoded, placement }: RenderGraphicCanvasProps) {
  const canvasRef = useCallback((canvas: HTMLCanvasElement | null) => {
    if (canvas === null || typeof ImageData === "undefined") return;
    const context = canvas.getContext("2d");
    if (context === null) return;
    const source = placement.source;
    canvas.width = source.width;
    canvas.height = source.height;
    const pixels = new ImageData(
      decoded.pixels,
      decoded.image.width,
      decoded.image.height,
    );
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
  plainChildren,
}: RenderGraphicsProps) {
  const { budget: graphicsBudget, decoder } = useGraphicsResources();
  const owner = useRef(Symbol("render-graphics")).current;
  const images = graphics?.images ?? EMPTY_IMAGES;
  const imageMetadata = useImageAdmissionMetadata(images);
  const candidateSource = useMemo(
    () => new RenderGraphicCandidateSource(
      graphics?.placements ?? EMPTY_PLACEMENTS,
      imageMetadata,
    ),
    [graphics?.placements, imageMetadata],
  );
  const subscribeBudget = useCallback(
    (listener: () => void) => graphicsBudget.subscribe(owner, listener),
    [graphicsBudget, owner],
  );
  const budgetSnapshot = useCallback(
    () => graphicsBudget.snapshot(owner),
    [graphicsBudget, owner],
  );
  const budgetRevision = useSyncExternalStore(
    subscribeBudget,
    budgetSnapshot,
    budgetSnapshot,
  );
  const selected = graphicsBudget.selected(owner);
  const admittedImages = useMemo(
    () => images.filter((image) => selected.images.has(image.id)),
    [budgetRevision, images, selected],
  );
  const decodedImages = useDecodedRenderGraphicImages(decoder, owner, admittedImages);
  const placements = useMemo(() => {
    const rendered = [...selected.placements]
      .flatMap((candidate): RenderedPlacement[] => {
        const decoded = decodedImages.get(candidate.imageId);
        return decoded === undefined
          ? []
          : [{
            decoded,
            order: candidate.order,
            placement: resolveRenderGraphicPlacementPlan(candidate.placement),
          }];
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
  }, [budgetRevision, decodedImages, selected]);
  const registerBudget = useCallback((element: HTMLSpanElement | null) => {
    if (element === null) return;
    graphicsBudget.update(owner, candidateSource);
    return () => graphicsBudget.scheduleRemove(owner);
  }, [candidateSource, graphicsBudget, owner]);
  const registration = (
    <span aria-hidden="true" hidden ref={registerBudget} />
  );
  const hasDrawablePlacement = placements.belowBackground.length > 0
    || placements.below.length > 0
    || placements.above.length > 0;
  if (!hasDrawablePlacement) {
    return (
      <>
        {registration}
        {plainChildren ?? children}
      </>
    );
  }

  return (
    <>
      {registration}
      <div
        aria-hidden="true"
        className="render-graphics-layer render-graphics-below-background"
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

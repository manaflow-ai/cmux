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
import type { RenderGraphicImage, RenderGraphicPlacement } from "cmux/browser";
import { useDecodedRenderGraphicImages } from "../hooks/useDecodedRenderGraphicImages";
import type { RenderGraphicsModel } from "../lib/renderModel";
import {
  planRenderGraphicPlacement,
  RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP,
  RENDER_GRAPHIC_CANVAS_COUNT_CAP,
  RENDER_GRAPHIC_DECODED_BYTE_CAP,
  renderGraphicImageKey,
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
  image: RenderGraphicImage;
  placement: RenderGraphicPlacementPlan;
  decodedBytes: number;
}

interface GraphicsSelection {
  placements: ReadonlySet<RenderGraphicCandidate>;
  images: ReadonlySet<string>;
}

interface RenderedPlacement {
  decoded: DecodedRenderGraphicImage;
  order: number;
  placement: ResolvedRenderGraphicPlacement;
}

interface ImageAdmissionMetadata {
  decodedBytes: number;
  image: RenderGraphicImage;
}

interface RawRenderGraphicCandidate extends CandidatePriority, ImageAdmissionMetadata {
  placement: RenderGraphicPlacement;
}

const EMPTY_IMAGES: readonly RenderGraphicImage[] = [];
const EMPTY_PLACEMENTS: readonly RenderGraphicPlacement[] = [];
const EMPTY_SELECTION: GraphicsSelection = {
  placements: new Set(),
  images: new Set(),
};
const CANDIDATE_PAGE_SIZE = RENDER_GRAPHIC_CANVAS_COUNT_CAP;

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
  private readonly ordered: RenderGraphicCandidate[] = [];
  private page: readonly RawRenderGraphicCandidate[] = [];
  private pageIndex = 0;
  private upperBound: CandidatePriority | undefined;
  private exhausted = false;

  constructor(
    private readonly placements: readonly RenderGraphicPlacement[],
    private readonly images: ReadonlyMap<number, ImageAdmissionMetadata>,
  ) {}

  candidateAt(index: number): RenderGraphicCandidate | undefined {
    while (this.ordered.length <= index) {
      const candidate = this.nextCandidate();
      if (candidate === undefined) break;
      this.ordered.push(candidate);
    }
    return this.ordered[index];
  }

  private nextCandidate(): RenderGraphicCandidate | undefined {
    while (true) {
      if (this.pageIndex >= this.page.length) {
        if (this.exhausted) return undefined;
        this.fillPage();
        if (this.page.length === 0) return undefined;
      }
      const raw = this.page[this.pageIndex++]!;
      const placement = planRenderGraphicPlacement(raw.image, raw.placement);
      if (placement === null) continue;
      return {
        image: raw.image,
        placement,
        order: raw.order,
        z: raw.z,
        decodedBytes: raw.decodedBytes,
      };
    }
  }

  private fillPage(): void {
    // Keep only one bounded page of lightweight placement references while
    // scanning. Full geometry plans and CSS strings are created only as the
    // global registry consumes candidates, and later pages refill rejected
    // byte-budget slots without materializing the whole protocol-sized list.
    const worstFirst: RawRenderGraphicCandidate[] = [];
    const compareWorst = (
      left: RawRenderGraphicCandidate,
      right: RawRenderGraphicCandidate,
    ) => -compareCandidates(left, right);
    for (const [order, placement] of this.placements.entries()) {
      if (!placement.viewport_visible || !Number.isSafeInteger(placement.z)) continue;
      const image = this.images.get(placement.image_id);
      if (image === undefined) continue;
      if (this.upperBound !== undefined
        && compareCandidateValues(
          placement.z,
          order,
          this.upperBound.z,
          this.upperBound.order,
        ) >= 0) continue;
      if (worstFirst.length < CANDIDATE_PAGE_SIZE) {
        heapPush(
          worstFirst,
          { ...image, placement, z: placement.z, order },
          compareWorst,
        );
        continue;
      }
      if (compareCandidateValues(
        placement.z,
        order,
        worstFirst[0].z,
        worstFirst[0].order,
      ) <= 0) continue;
      const replacement = worstFirst[0];
      replacement.decodedBytes = image.decodedBytes;
      replacement.image = image.image;
      replacement.placement = placement;
      replacement.z = placement.z;
      replacement.order = order;
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
    this.page = worstFirst.sort((left, right) => -compareCandidates(left, right));
    this.pageIndex = 0;
    const last = this.page.at(-1);
    if (last === undefined) {
      this.exhausted = true;
      return;
    }
    this.upperBound = { z: last.z, order: last.order };
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
      const candidate = state.source.candidateAt(0);
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
      if (candidate.placement.backingBytes
        <= RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP - backingBytes) {
        const images = nextImages.get(owner)!;
        const imageKey = renderGraphicImageKey(candidate.image);
        if (images.has(imageKey)
          || candidate.decodedBytes <= RENDER_GRAPHIC_DECODED_BYTE_CAP - decodedBytes) {
          nextPlacements.get(owner)!.add(candidate);
          if (!images.has(imageKey)) {
            images.add(imageKey);
            decodedBytes += candidate.decodedBytes;
          }
          backingBytes += candidate.placement.backingBytes;
          admitted += 1;
        }
      }
      if (admitted >= RENDER_GRAPHIC_CANVAS_COUNT_CAP) continue;
      const nextIndex = index + 1;
      const nextCandidate = this.candidates.get(owner)?.source.candidateAt(nextIndex);
      if (nextCandidate !== undefined) {
        heapPush(cursors, {
          owner,
          ownerOrder,
          candidate: nextCandidate,
          index: nextIndex,
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
        || [...selection.images].some((imageKey) => !previous.images.has(imageKey));
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
}

const GraphicsResourcesContext = createContext<RenderGraphicsResources | null>(null);

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
  plainChildren,
}: RenderGraphicsProps) {
  const { budget: graphicsBudget, decoder } = useGraphicsResources();
  const owner = useRef(Symbol("render-graphics")).current;
  const images = graphics?.images ?? EMPTY_IMAGES;
  const imageMetadata = useMemo(() => {
    const metadata = new Map<number, ImageAdmissionMetadata>();
    for (const image of images) {
      const decodedBytes = renderGraphicRgbaByteLength(image);
      if (decodedBytes !== null) metadata.set(image.id, { image, decodedBytes });
    }
    return metadata;
  }, [images]);
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
    () => images.filter((image) => selected.images.has(renderGraphicImageKey(image))),
    [budgetRevision, images, selected],
  );
  const decodedImages = useDecodedRenderGraphicImages(decoder, owner, admittedImages);
  const placements = useMemo(() => {
    const rendered = [...selected.placements]
      .flatMap((candidate): RenderedPlacement[] => {
        const decoded = decodedImages.get(candidate.image.id);
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

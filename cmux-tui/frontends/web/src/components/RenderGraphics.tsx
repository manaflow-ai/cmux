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
  renderGraphicRgbaByteLength,
  resolveRenderGraphicPlacement,
  type DecodedRenderGraphicImage,
  type ResolvedRenderGraphicPlacement,
} from "../lib/renderGraphics";

interface RenderGraphicsProps {
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
  images: ReadonlySet<RenderGraphicImage>;
}

interface RenderedPlacement extends RenderGraphicCandidate {
  decoded: DecodedRenderGraphicImage;
}

const EMPTY_IMAGES: readonly RenderGraphicImage[] = [];
const EMPTY_SELECTION: GraphicsSelection = {
  placements: new Set(),
  images: new Set(),
};

class GraphicsBudgetRegistry {
  private readonly candidates = new Map<symbol, readonly RenderGraphicCandidate[]>();
  private readonly selections = new Map<symbol, GraphicsSelection>();
  private readonly listeners = new Set<() => void>();
  private revision = 0;

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly snapshot = (): number => this.revision;

  selected(owner: symbol): GraphicsSelection {
    return this.selections.get(owner) ?? EMPTY_SELECTION;
  }

  update(owner: symbol, candidates: readonly RenderGraphicCandidate[]): void {
    this.candidates.set(owner, candidates);
    this.recalculate();
  }

  remove(owner: symbol): void {
    if (!this.candidates.delete(owner)) return;
    this.recalculate();
  }

  private recalculate(): void {
    const ranked: Array<{
      owner: symbol;
      candidate: RenderGraphicCandidate;
      sequence: number;
    }> = [];
    let sequence = 0;
    for (const [owner, candidates] of this.candidates) {
      for (const candidate of candidates) {
        ranked.push({ owner, candidate, sequence });
        sequence += 1;
      }
    }
    ranked.sort((left, right) =>
      right.candidate.placement.z - left.candidate.placement.z
      || right.candidate.order - left.candidate.order
      || left.sequence - right.sequence
    );

    const nextPlacements = new Map<symbol, Set<RenderGraphicCandidate>>();
    const nextImages = new Map<symbol, Set<RenderGraphicImage>>();
    for (const owner of this.candidates.keys()) {
      nextPlacements.set(owner, new Set());
      nextImages.set(owner, new Set());
    }
    let admitted = 0;
    let backingBytes = 0;
    let decodedBytes = 0;
    for (const { owner, candidate } of ranked) {
      if (admitted >= RENDER_GRAPHIC_CANVAS_COUNT_CAP) break;
      if (candidate.placement.backingBytes
        > RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP - backingBytes) continue;
      const images = nextImages.get(owner)!;
      if (!images.has(candidate.image)
        && candidate.decodedBytes > RENDER_GRAPHIC_DECODED_BYTE_CAP - decodedBytes) continue;
      nextPlacements.get(owner)!.add(candidate);
      if (!images.has(candidate.image)) {
        images.add(candidate.image);
        decodedBytes += candidate.decodedBytes;
      }
      backingBytes += candidate.placement.backingBytes;
      admitted += 1;
    }

    const next = new Map<symbol, GraphicsSelection>();
    for (const [owner, placements] of nextPlacements) {
      next.set(owner, { placements, images: nextImages.get(owner)! });
    }
    const changed = next.size !== this.selections.size
      || [...next].some(([owner, selection]) => {
        const previous = this.selections.get(owner);
        return previous === undefined
          || previous.placements.size !== selection.placements.size
          || previous.images.size !== selection.images.size
          || [...selection.placements].some((candidate) =>
            !previous.placements.has(candidate)
          )
          || [...selection.images].some((image) => !previous.images.has(image));
      });
    if (!changed) return;
    this.selections.clear();
    for (const [owner, selection] of next) this.selections.set(owner, selection);
    this.revision += 1;
    for (const listener of this.listeners) listener();
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

export function RenderGraphics({ children, graphics }: RenderGraphicsProps) {
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
    return rendered.sort((left, right) =>
      right.placement.z - left.placement.z || right.order - left.order
    );
  }, [graphics?.placements, imageById]);
  const budgetRevision = useSyncExternalStore(
    graphicsBudget.subscribe,
    graphicsBudget.snapshot,
    graphicsBudget.snapshot,
  );
  const selected = graphicsBudget.selected(owner);
  const admittedImages = useMemo(
    () => images.filter((image) => selected.images.has(image)),
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
    const below: RenderedPlacement[] = [];
    const above: RenderedPlacement[] = [];
    for (const candidate of rendered) {
      (candidate.placement.layer === "below" ? below : above).push(candidate);
    }
    return { below, above };
  }, [budgetRevision, candidates, decodedImages, selected]);
  const registerBudget = useCallback((element: HTMLDivElement | null) => {
    if (element === null) return;
    graphicsBudget.update(owner, candidates);
    return () => graphicsBudget.remove(owner);
  }, [candidates, owner]);

  return (
    <>
      <div
        aria-hidden="true"
        className="render-graphics-layer render-graphics-below"
        ref={registerBudget}
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

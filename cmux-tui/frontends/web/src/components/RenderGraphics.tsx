import {
  useCallback,
  useMemo,
  useRef,
  useSyncExternalStore,
  type CSSProperties,
  type ReactNode,
} from "react";
import { useDecodedRenderGraphicImages } from "../hooks/useDecodedRenderGraphicImages";
import type { RenderGraphicsModel } from "../lib/renderModel";
import {
  RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP,
  RENDER_GRAPHIC_CANVAS_COUNT_CAP,
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

interface RenderedPlacement {
  decoded: DecodedRenderGraphicImage;
  placement: ResolvedRenderGraphicPlacement;
  order: number;
}

const EMPTY_SELECTION: ReadonlySet<string> = new Set();

class CanvasBudgetRegistry {
  private readonly candidates = new Map<symbol, readonly RenderedPlacement[]>();
  private readonly selections = new Map<symbol, ReadonlySet<string>>();
  private readonly listeners = new Set<() => void>();
  private revision = 0;

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly snapshot = (): number => this.revision;

  selected(owner: symbol): ReadonlySet<string> {
    return this.selections.get(owner) ?? EMPTY_SELECTION;
  }

  update(owner: symbol, candidates: readonly RenderedPlacement[]): void {
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
      candidate: RenderedPlacement;
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

    const next = new Map<symbol, Set<string>>();
    for (const owner of this.candidates.keys()) next.set(owner, new Set());
    let admitted = 0;
    let backingBytes = 0;
    for (const { owner, candidate } of ranked) {
      if (admitted >= RENDER_GRAPHIC_CANVAS_COUNT_CAP) break;
      if (candidate.placement.backingBytes
        > RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP - backingBytes) continue;
      next.get(owner)!.add(candidate.placement.key);
      backingBytes += candidate.placement.backingBytes;
      admitted += 1;
    }

    const changed = next.size !== this.selections.size
      || [...next].some(([owner, selected]) => {
        const previous = this.selections.get(owner);
        return previous === undefined
          || previous.size !== selected.size
          || [...selected].some((key) => !previous.has(key));
      });
    if (!changed) return;
    this.selections.clear();
    for (const [owner, selected] of next) this.selections.set(owner, selected);
    this.revision += 1;
    for (const listener of this.listeners) listener();
  }
}

const canvasBudget = new CanvasBudgetRegistry();

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
  const decodedImages = useDecodedRenderGraphicImages(graphics?.images ?? []);
  const owner = useRef(Symbol("render-graphics")).current;
  const candidates = useMemo(() => {
    const rendered: RenderedPlacement[] = [];
    for (const [order, candidate] of (graphics?.placements ?? []).entries()) {
      const decoded = decodedImages.get(candidate.image_id);
      if (decoded === undefined) continue;
      const placement = resolveRenderGraphicPlacement(decoded.image, candidate);
      if (placement !== null) rendered.push({ decoded, placement, order });
    }
    return rendered.sort((left, right) =>
      right.placement.z - left.placement.z || right.order - left.order
    );
  }, [decodedImages, graphics?.placements]);
  const budgetRevision = useSyncExternalStore(
    canvasBudget.subscribe,
    canvasBudget.snapshot,
    canvasBudget.snapshot,
  );
  const selected = canvasBudget.selected(owner);
  const placements = useMemo(() => {
    const rendered = candidates
      .filter((candidate) => selected.has(candidate.placement.key))
      .sort((left, right) =>
        left.placement.z - right.placement.z || left.order - right.order
      );
    const below: RenderedPlacement[] = [];
    const above: RenderedPlacement[] = [];
    for (const candidate of rendered) {
      (candidate.placement.layer === "below" ? below : above).push(candidate);
    }
    return { below, above };
  }, [budgetRevision, candidates, selected]);
  const registerBudget = useCallback((element: HTMLDivElement | null) => {
    if (element === null) return;
    canvasBudget.update(owner, candidates);
    return () => canvasBudget.remove(owner);
  }, [candidates, owner]);

  return (
    <>
      <div
        aria-hidden="true"
        className="render-graphics-layer render-graphics-below"
        ref={registerBudget}
      >
        {placements.below.map(({ decoded, placement }) => (
          <RenderGraphicCanvas decoded={decoded} key={placement.key} placement={placement} />
        ))}
      </div>
      {children}
      <div aria-hidden="true" className="render-graphics-layer render-graphics-above">
        {placements.above.map(({ decoded, placement }) => (
          <RenderGraphicCanvas decoded={decoded} key={placement.key} placement={placement} />
        ))}
      </div>
    </>
  );
}

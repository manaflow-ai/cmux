import {
  useCallback,
  useMemo,
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
  const placements = useMemo(() => {
    const rendered: RenderedPlacement[] = [];
    for (const [order, candidate] of (graphics?.placements ?? []).entries()) {
      const decoded = decodedImages.get(candidate.image_id);
      if (decoded === undefined) continue;
      const placement = resolveRenderGraphicPlacement(decoded.image, candidate);
      if (placement !== null) rendered.push({ decoded, placement, order });
    }
    rendered.sort((left, right) =>
      left.placement.z - right.placement.z || left.order - right.order
    );
    const below: RenderedPlacement[] = [];
    const above: RenderedPlacement[] = [];
    let admitted = 0;
    let backingBytes = 0;
    for (const candidate of rendered) {
      if (admitted >= RENDER_GRAPHIC_CANVAS_COUNT_CAP) break;
      if (candidate.placement.backingBytes
        > RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP - backingBytes) continue;
      backingBytes += candidate.placement.backingBytes;
      admitted += 1;
      (candidate.placement.layer === "below" ? below : above).push(candidate);
    }
    return { below, above };
  }, [decodedImages, graphics?.placements]);

  return (
    <>
      <div aria-hidden="true" className="render-graphics-layer render-graphics-below">
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

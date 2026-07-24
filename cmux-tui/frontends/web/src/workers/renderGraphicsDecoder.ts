import type { RenderGraphicImage } from "cmux/browser";
import { decodeRenderGraphicImage } from "../lib/renderGraphics";

export interface RenderGraphicsDecodeRequest {
  requestId: number;
  images: RenderGraphicImage[];
}

export interface RenderGraphicsDecodeResult {
  id: number;
  generation: number;
  pixels: ArrayBuffer | null;
}

export interface RenderGraphicsDecodeResponse {
  requestId: number;
  results: RenderGraphicsDecodeResult[];
}

interface DecoderWorkerScope {
  onmessage: ((event: MessageEvent<RenderGraphicsDecodeRequest>) => void) | null;
  postMessage(message: RenderGraphicsDecodeResponse, transfer: Transferable[]): void;
}

const scope = globalThis as unknown as DecoderWorkerScope;

scope.onmessage = ({ data: request }) => {
  const transfer: Transferable[] = [];
  const results = request.images.map((image): RenderGraphicsDecodeResult => {
    const decoded = decodeRenderGraphicImage(image);
    if (decoded === null) {
      return { id: image.id, generation: image.generation, pixels: null };
    }
    const pixels = decoded.pixels.buffer;
    transfer.push(pixels);
    return { id: image.id, generation: image.generation, pixels };
  });
  scope.postMessage({ requestId: request.requestId, results }, transfer);
};

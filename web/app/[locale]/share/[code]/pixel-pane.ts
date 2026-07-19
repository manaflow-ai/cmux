// Pixel-pane decoding for non-terminal panes (slice 2): H.264 via WebCodecs
// when available, still images (JPEG/WebP, sniffed) as the universal
// fallback. Each model owns one pane's decode state and holds the latest
// drawable image; components paint it into a canvas on notification,
// mirroring the terminal grid path.

import { PIXEL_CODEC_H264_ANNEXB, PIXEL_CODEC_STILL, PIXEL_FLAG_KEYFRAME } from "./share-protocol";

type Listener = () => void;

export class PixelPaneModel {
  /** Latest decoded image, ready to draw. */
  image: ImageBitmap | VideoFrame | null = null;
  generation = 0;
  private listeners = new Set<Listener>();
  private decoder: VideoDecoder | null = null;
  private sawKeyframe = false;
  private timestamp = 0;
  private closed = false;
  /** Latest-wins still decoding: at most one decode in flight, and only the
   * newest pending frame is decoded next (stale stills are dropped). */
  private stillDecoding = false;
  private pendingStill: Uint8Array | null = null;

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /** Payload after the binary header: [codec u8][flags u8][data]. */
  push(payload: Uint8Array): void {
    if (this.closed || payload.length < 2) return;
    const codec = payload[0] ?? 0;
    const flags = payload[1] ?? 0;
    const data = payload.subarray(2);
    if (codec === PIXEL_CODEC_STILL) {
      this.pushStill(data);
    } else if (codec === PIXEL_CODEC_H264_ANNEXB) {
      this.pushVideo(data, (flags & PIXEL_FLAG_KEYFRAME) !== 0);
    }
  }

  close(): void {
    this.closed = true;
    this.pendingStill = null;
    try {
      this.decoder?.close();
    } catch {
      // Already closed.
    }
    this.decoder = null;
    this.dropImage();
  }

  private pushStill(data: Uint8Array): void {
    this.pendingStill = data;
    if (this.stillDecoding) return;
    this.stillDecoding = true;
    void this.decodeNextStill();
  }

  private async decodeNextStill(): Promise<void> {
    while (!this.closed && this.pendingStill) {
      const data = this.pendingStill;
      this.pendingStill = null;
      try {
        // No MIME type: createImageBitmap sniffs, so JPEG and WebP both work.
        const bitmap = await createImageBitmap(new Blob([data.slice()]));
        if (this.closed) {
          bitmap.close();
        } else {
          this.setImage(bitmap);
        }
      } catch {
        // Undecodable still; keep showing the previous frame.
      }
    }
    this.stillDecoding = false;
  }

  private pushVideo(data: Uint8Array, keyframe: boolean): void {
    if (typeof VideoDecoder === "undefined") return; // stills-only browser
    if (!this.decoder) {
      if (!keyframe) return; // cannot start mid-stream
      const decoder = new VideoDecoder({
        output: (frame) => this.setImage(frame),
        error: () => {
          // Corrupt stream: reset and wait for the next keyframe.
          this.decoder = null;
          this.sawKeyframe = false;
        },
      });
      // No `description` = Annex B; parameter sets ride inline on keyframes.
      decoder.configure({ codec: "avc1.42E01E", optimizeForLatency: true });
      this.decoder = decoder;
    }
    if (keyframe) this.sawKeyframe = true;
    if (!this.sawKeyframe) return;
    this.timestamp += 1;
    try {
      this.decoder.decode(
        new EncodedVideoChunk({
          type: keyframe ? "key" : "delta",
          timestamp: this.timestamp,
          data: data.slice(),
        }),
      );
    } catch {
      this.decoder?.close();
      this.decoder = null;
      this.sawKeyframe = false;
    }
  }

  private setImage(image: ImageBitmap | VideoFrame): void {
    this.dropImage();
    this.image = image;
    this.generation += 1;
    for (const l of this.listeners) l();
  }

  private dropImage(): void {
    if (this.image && "close" in this.image) this.image.close();
    this.image = null;
  }
}

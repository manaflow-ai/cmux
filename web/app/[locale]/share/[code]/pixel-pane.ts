// Pixel-pane decoding for non-terminal panes (slice 2): H.264 via WebCodecs
// when available, WebP stills as the universal fallback. Each model owns one
// pane's decode state and holds the latest drawable image; components paint
// it into a canvas on notification, mirroring the terminal grid path.

import { PIXEL_CODEC_H264_ANNEXB, PIXEL_CODEC_WEBP, PIXEL_FLAG_KEYFRAME } from "./share-protocol";

type Listener = () => void;

export class PixelPaneModel {
  /** Latest decoded image, ready to draw. */
  image: ImageBitmap | VideoFrame | null = null;
  generation = 0;
  private listeners = new Set<Listener>();
  private decoder: VideoDecoder | null = null;
  private sawKeyframe = false;
  private timestamp = 0;
  /** Serializes WebP decodes so a slow decode can't reorder frames. */
  private stillChain: Promise<void> = Promise.resolve();

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /** Payload after the binary header: [codec u8][flags u8][data]. */
  push(payload: Uint8Array): void {
    if (payload.length < 2) return;
    const codec = payload[0] ?? 0;
    const flags = payload[1] ?? 0;
    const data = payload.subarray(2);
    if (codec === PIXEL_CODEC_WEBP) {
      this.pushStill(data);
    } else if (codec === PIXEL_CODEC_H264_ANNEXB) {
      this.pushVideo(data, (flags & PIXEL_FLAG_KEYFRAME) !== 0);
    }
  }

  close(): void {
    this.decoder?.close();
    this.decoder = null;
    this.dropImage();
  }

  private pushStill(data: Uint8Array): void {
    const blob = new Blob([data.slice()], { type: "image/webp" });
    this.stillChain = this.stillChain
      .then(() => createImageBitmap(blob))
      .then((bitmap) => this.setImage(bitmap))
      .catch(() => {
        // Undecodable still; keep showing the previous frame.
      });
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

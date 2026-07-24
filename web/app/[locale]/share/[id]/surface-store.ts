// Routes host terminal output to the pane that renders it. Chunks that
// arrive before a pane's terminal is ready are buffered; sequence gaps are
// tolerated (we render on) per the share viewer spec.

export interface SurfaceSink {
  write(bytes: Uint8Array): void;
  resize(cols: number, rows: number): void;
}

interface SurfaceFeed {
  lastSeq: number | null;
  pending: Uint8Array[];
  pendingResize: { cols: number; rows: number } | null;
  sink: SurfaceSink | null;
}

export class SurfaceStore {
  private feeds = new Map<string, SurfaceFeed>();

  private feed(surfaceId: string): SurfaceFeed {
    let feed = this.feeds.get(surfaceId);
    if (!feed) {
      feed = { lastSeq: null, pending: [], pendingResize: null, sink: null };
      this.feeds.set(surfaceId, feed);
    }
    return feed;
  }

  /** Called when a snapshot arrives: drops stale buffered output. */
  setBaseline(surfaceId: string, replaySeq: number | undefined): void {
    const feed = this.feed(surfaceId);
    feed.pending = [];
    feed.lastSeq = replaySeq ?? null;
  }

  /** Snapshot replay: resets the feed baseline, then writes replay bytes. */
  applySnapshot(
    surfaceId: string,
    bytes: Uint8Array,
    replaySeq: number | undefined,
  ): void {
    const feed = this.feed(surfaceId);
    feed.pending = [];
    feed.lastSeq = replaySeq ?? null;
    if (feed.sink) {
      feed.sink.write(bytes);
    } else {
      feed.pending.push(bytes);
    }
  }

  pushChunk(surfaceId: string, seq: number, bytes: Uint8Array): void {
    const feed = this.feed(surfaceId);
    if (feed.lastSeq !== null && seq <= feed.lastSeq) return;
    feed.lastSeq = seq;
    if (feed.sink) {
      feed.sink.write(bytes);
    } else {
      feed.pending.push(bytes);
    }
  }

  pushResize(surfaceId: string, cols: number, rows: number): void {
    const feed = this.feed(surfaceId);
    if (feed.sink) {
      feed.sink.resize(cols, rows);
    } else {
      feed.pendingResize = { cols, rows };
    }
  }

  attach(surfaceId: string, sink: SurfaceSink): void {
    const feed = this.feed(surfaceId);
    feed.sink = sink;
    if (feed.pendingResize) {
      sink.resize(feed.pendingResize.cols, feed.pendingResize.rows);
      feed.pendingResize = null;
    }
    for (const bytes of feed.pending) {
      sink.write(bytes);
    }
    feed.pending = [];
  }

  detach(surfaceId: string, sink: SurfaceSink): void {
    const feed = this.feeds.get(surfaceId);
    if (feed && feed.sink === sink) {
      feed.sink = null;
    }
  }

  reset(): void {
    this.feeds.clear();
  }
}

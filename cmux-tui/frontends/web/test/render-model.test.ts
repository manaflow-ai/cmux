import { describe, expect, it, vi } from "vitest";
import type {
  RenderGraphicImage,
  RenderCursor,
  RenderDeltaEvent,
  RenderGraphics,
  RenderRow,
  RenderStateEvent,
} from "cmux/raw";
import { decodeRenderGraphicImage } from "../src/lib/renderGraphics";
import * as renderModelApi from "../src/lib/renderModel";
import {
  applyDelta,
  applySnapshot,
  releaseRenderModelGraphicsBudget,
} from "../src/lib/renderModel";

const cursor: RenderCursor = {
  x: 1,
  y: 0,
  style: "block",
  blink: true,
  visible: true,
  color: null,
};

function row(index: number, text: string): RenderRow {
  return { row: index, runs: [{ text, fg: null, bg: null, attrs: 0 }] };
}

const graphics: RenderGraphics = {
  generation: 4n,
  images: [{
    id: 9,
    generation: 2n,
    width: 1,
    height: 1,
    format: "rgba",
    data: "/wAA/w==",
  }, {
    id: 10,
    generation: 1n,
    width: 1,
    height: 1,
    format: "rgb",
    data: "AP8A",
  }],
  placements: [{
    image_id: 9,
    placement_id: 3,
    ordinal: 0,
    x_offset: 0,
    y_offset: 0,
    source_x: 0,
    source_y: 0,
    source_width: 1,
    source_height: 1,
    columns: 1,
    rows: 1,
    grid_cols: 1,
    grid_rows: 1,
    pixel_width: 8,
    pixel_height: 16,
    viewport_col: 1,
    viewport_row: 0,
    viewport_visible: true,
    anchor_col: 1,
    anchor_row: 0,
    z: 0,
  }],
};

function snapshot(
  rows: RenderRow[] = [row(0, "one"), row(1, "two")],
  renderGraphics: RenderGraphics | undefined = graphics,
): RenderStateEvent {
  return {
    event: "render-state",
    surface: 7n,
    size: { cols: 3, rows: 2 },
    cursor,
    default_fg: "#eeeeee",
    default_bg: "#111111",
    scrollback_rows: 12,
    history_epoch: 5n,
    rows,
    graphics: renderGraphics,
  } as RenderStateEvent;
}

function delta(overrides: Partial<RenderDeltaEvent> = {}): RenderDeltaEvent {
  return {
    event: "render-delta",
    surface: 7n,
    cursor,
    full: false,
    rows: [],
    ...overrides,
  };
}

describe("render model", () => {
  it("tracks retained-history epochs across snapshots and deltas", () => {
    const initial = applySnapshot(snapshot());
    const updated = applyDelta(initial, delta({ history_epoch: 9n } as Partial<RenderDeltaEvent>));

    expect((initial as { historyEpoch?: bigint }).historyEpoch).toBe(5n);
    expect((updated as { historyEpoch?: bigint }).historyEpoch).toBe(9n);
  });

  it("indexes snapshot and dirty rows by row number even when events list them out of order", () => {
    const initial = applySnapshot(snapshot([row(1, "two"), row(0, "one")]));
    const updated = applyDelta(initial, delta({ rows: [row(1, "TWO"), row(0, "ONE")] }));

    expect(initial.rows.map((candidate) => candidate.runs[0]?.text)).toEqual(["one", "two"]);
    expect(updated.rows.map((candidate) => candidate.runs[0]?.text)).toEqual(["ONE", "TWO"]);
  });

  it("ignores invalid row indexes and deltas buffered for another surface", () => {
    const initial = applySnapshot(snapshot());
    const invalidRows = applyDelta(initial, delta({ rows: [row(-1, "bad"), row(8, "bad")] }));
    const staleSurface = applyDelta(initial, delta({ surface: 99n, rows: [row(0, "stale")] }));

    expect(invalidRows.rows.map((candidate) => candidate.runs[0]?.text)).toEqual(["one", "two"]);
    expect(staleSurface).toBe(initial);
  });

  it("treats a resize as a full viewport replacement", () => {
    const initial = applySnapshot(snapshot());
    const resized = applyDelta(initial, delta({
      full: true,
      size: { cols: 4, rows: 3 },
      rows: [row(2, "new2"), row(0, "new0"), row(1, "new1")],
      scrollback_rows: 20,
    }));

    expect(resized.size).toEqual({ cols: 4, rows: 3 });
    expect(resized.rows.map((candidate) => candidate.runs[0]?.text)).toEqual(["new0", "new1", "new2"]);
    expect(resized.scrollbackRows).toBe(20);
  });

  it("replaces all rows for a full repaint without a resize", () => {
    const initial = applySnapshot(snapshot());
    const replaced = applyDelta(initial, delta({ full: true, rows: [row(0, "new")] }));

    expect(replaced.rows[0]?.runs[0]?.text).toBe("new");
    expect(replaced.rows[1]?.runs).toEqual([]);
  });

  it("updates cursor and defaults without copying the row array", () => {
    const initial = applySnapshot(snapshot());
    const updated = applyDelta(initial, delta({
      cursor: { ...cursor, x: 2, style: "bar", visible: false },
      default_bg: "#222222",
    }));

    expect(updated.rows).toBe(initial.rows);
    expect(updated.cursor).toMatchObject({ x: 2, style: "bar", visible: false });
    expect(updated.defaultBg).toBe("#222222");
  });

  it("applies image pixels and authoritative placements from snapshots and deltas", () => {
    const initial = applySnapshot(snapshot());
    const moved = applyDelta(initial, delta({
      graphics: {
        generation: 4n,
        placements: [{ ...graphics.placements[0], viewport_col: 2 }],
      },
    }));
    const replaced = applyDelta(moved, delta({
      graphics: {
        generation: 5n,
        images: [{
          ...graphics.images![0],
          generation: 3n,
          data: "AAD//w==",
        }],
        placements: [{ ...graphics.placements[0], viewport_col: 3 }],
      },
    }));

    expect(initial.graphics.images[0]?.data).toBe("/wAA/w==");
    expect(moved.graphics.images).toBe(initial.graphics.images);
    expect(moved.graphics.placements[0]?.viewport_col).toBe(2);
    expect(replaced.graphics.images[0]).toMatchObject({ generation: 3n, data: "AAD//w==" });
    expect(replaced.graphics.images[1]).toBe(initial.graphics.images[1]);
    expect(replaced.graphics.placements[0]?.viewport_col).toBe(3);
  });

  it("applies placement deltas that only change absolute history anchors", () => {
    const initial = applySnapshot(snapshot());
    const reanchored = applyDelta(initial, delta({
      graphics: {
        generation: initial.graphics.generation,
        placements: [{ ...graphics.placements[0], anchor_row: 4 }],
      },
    }));

    expect(reanchored.graphics.placements).not.toBe(initial.graphics.placements);
    expect(reanchored.graphics.placements[0]?.anchor_row).toBe(4);
  });

  it("does not scan image payload characters on the browser thread", () => {
    const charCodeAt = vi.spyOn(String.prototype, "charCodeAt");
    try {
      const initial = applySnapshot(snapshot());
      expect(charCodeAt).not.toHaveBeenCalled();

      const moved = applyDelta(initial, delta({
        graphics: {
          generation: 5n,
          placements: [{ ...graphics.placements[0], viewport_col: 2 }],
        },
      }));
      expect(moved.graphics.images).toBe(initial.graphics.images);
      expect(charCodeAt).not.toHaveBeenCalled();

      applyDelta(moved, delta({
        graphics: {
          generation: 6n,
          images: [{
            ...graphics.images![0],
            generation: 3n,
            data: "AAD//w==",
          }],
        },
      }));
      expect(charCodeAt).not.toHaveBeenCalled();
    } finally {
      charCodeAt.mockRestore();
    }
  });

  it("preserves placements for image-only graphics deltas", () => {
    const initial = applySnapshot(snapshot());
    const replaced = applyDelta(initial, delta({
      graphics: {
        generation: 5n,
        images: [{
          ...graphics.images![0],
          generation: 3n,
          data: "AAD//w==",
        }],
      },
    }));

    expect(replaced.graphics.images[0]).toMatchObject({ generation: 3n, data: "AAD//w==" });
    expect(replaced.graphics.placements).toBe(initial.graphics.placements);
  });

  it("removes images and placements only when a graphics update says they are gone", () => {
    const initial = applySnapshot(snapshot());
    const textOnly = applyDelta(initial, delta({ rows: [row(0, "text")] }));
    const removed = applyDelta(textOnly, delta({
      graphics: {
        generation: 5n,
        removed_image_ids: [9, 10],
        placements: [],
      },
    }));

    expect(textOnly.graphics).toBe(initial.graphics);
    expect(textOnly.rows[0]?.runs[0]?.text).toBe("text");
    expect(removed.graphics.images).toEqual([]);
    expect(removed.graphics.placements).toEqual([]);
  });

  it("starts with empty graphics when attached to an older additive protocol server", () => {
    expect(applySnapshot({ ...snapshot(), graphics: undefined }).graphics).toEqual({
      generation: 0n,
      images: [],
      placements: [],
    });
  });

  it("bounds encoded image payloads and requests a resnapshot when capacity returns", async () => {
    const encodedBudget = {};
    const budgetedApplySnapshot = applySnapshot as unknown as (
      event: RenderStateEvent,
      budget: object,
      owner: object,
    ) => ReturnType<typeof applySnapshot>;
    const data = `${"A".repeat(13_333_334)}==`;
    const image: RenderGraphicImage = {
      id: 1,
      generation: 1n,
      width: 2_500_000,
      height: 1,
      format: "rgba",
      data,
    };

    const owners = Array.from({ length: 7 }, () => ({}));
    const models = owners.map((owner) =>
      budgetedApplySnapshot(
        snapshot([], { generation: 1n, images: [image], placements: [] }),
        encodedBudget,
        owner,
      )
    );
    const retained = models.reduce(
      (total, model) =>
        total + model.graphics.images.reduce((sum, candidate) => sum + candidate.data.length, 0),
      0,
    );

    expect(retained).toBeLessThanOrEqual(64 * 1024 * 1024);
    expect(models.some((model) => model.graphics.images.length === 0)).toBe(true);

    const subscribe = (
      renderModelApi as unknown as {
        subscribeRenderModelGraphicsBudget?: (
          budget: object,
          owner: object,
          listener: () => void,
        ) => () => void;
      }
    ).subscribeRenderModelGraphicsBudget;
    if (subscribe === undefined) {
      throw new Error("encoded graphics budget does not expose recovery subscriptions");
    }
    const requestResnapshot = vi.fn();
    const unsubscribe = subscribe(encodedBudget, owners.at(-1)!, requestResnapshot);
    const budgetedApplyDelta = applyDelta as unknown as (
      model: ReturnType<typeof applySnapshot>,
      event: RenderDeltaEvent,
      budget: object,
      owner: object,
    ) => ReturnType<typeof applyDelta>;
    budgetedApplyDelta(
      models.at(-1)!,
      delta({ graphics: { generation: 2n, placements: [] } }),
      encodedBudget,
      owners.at(-1)!,
    );
    releaseRenderModelGraphicsBudget(encodedBudget, owners[0]!);
    await Promise.resolve();
    expect(requestResnapshot).toHaveBeenCalledTimes(1);
    unsubscribe();

    const recovered = budgetedApplySnapshot(
      snapshot([], { generation: 2n, images: [image], placements: [] }),
      encodedBudget,
      owners.at(-1)!,
    );
    expect(recovered.graphics.images).toHaveLength(1);
  });

  it("rejects snapshots whose retained images exceed the decoded byte budget", () => {
    const image = (id: number): RenderGraphicImage => ({
      id,
      generation: 1n,
      width: 1_250_001,
      height: 1,
      format: "rgba",
      data: "A".repeat(6_666_672),
    });

    expect(() => applySnapshot(snapshot([], {
      generation: 1n,
      images: [image(1), image(2)],
      placements: [],
    }))).toThrow(/exceeds 10000000 decoded image bytes/);
  });

  it("rejects incremental image growth beyond the authoritative byte budget", () => {
    const image = (id: number): RenderGraphicImage => ({
      id,
      generation: 1n,
      width: 1_250_000,
      height: 1,
      format: "rgba",
      data: `${"A".repeat(6_666_667)}=`,
    });
    const initial = applySnapshot(snapshot([], {
      generation: 1n,
      images: [image(1)],
      placements: [],
    }));

    expect(() => applyDelta(initial, delta({
      graphics: { generation: 2n, images: [image(2)] },
    }))).not.toThrow();
    const full = applyDelta(initial, delta({
      graphics: { generation: 2n, images: [image(2)] },
    }));
    expect(() => applyDelta(full, delta({
      graphics: { generation: 3n, images: [{ ...image(3), width: 1, data: "AAAAAA==" }] },
    }))).toThrow(/exceeds 10000000 decoded image bytes/);
  });

  it("rejects too many retained images across incremental deltas", () => {
    const images = Array.from({ length: 4_096 }, (_, index): RenderGraphicImage => ({
      id: index,
      generation: 1n,
      width: 1,
      height: 1,
      format: "rgb",
      data: "AAAA",
    }));
    const initial = applySnapshot(snapshot([], {
      generation: 1n,
      images,
      placements: [],
    }));

    expect(() => applyDelta(initial, delta({
      graphics: {
        generation: 2n,
        images: [{ ...images[0]!, id: images.length }],
      },
    }))).toThrow(/exceeds 4096 images/);
  });

  it("rejects encoded image data that does not match its dimensions", () => {
    expect(() => applySnapshot(snapshot([], {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width: 1,
        height: 1,
        format: "rgba",
        data: "A".repeat(1_000_000),
      }],
      placements: [],
    }))).toThrow(/pixel data does not match its dimensions/);
  });

  it("defers full base64 validation to the image decoder", () => {
    const image: RenderGraphicImage = {
      id: 1,
      generation: 1n,
      width: 1,
      height: 1,
      format: "rgb",
      data: "AAA!",
    };
    const model = applySnapshot(snapshot([], {
      generation: 1n,
      images: [image],
      placements: [],
    }));

    expect(model.graphics.images).toHaveLength(1);
    expect(decodeRenderGraphicImage(image)).toBeNull();
  });
});

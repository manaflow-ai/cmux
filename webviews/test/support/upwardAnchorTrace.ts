export type UpwardAnchorFrame = {
  frame: number;
  paint: number;
  topRowId: string | null;
  topRowY: number | null;
  requestedPixels: number;
  wheelPixels: number;
  scrollTop: number;
  anchorId: string | null;
  drift: number | null;
  rowBoxGap: number;
  rowBoxIds: string[];
};

/** Runs in the page with paintedFrames installed; it deliberately closes over no test state. */
export async function traceUpwardAnchors({ steps, restFrames = 24 }: { steps: number[]; restFrames?: number }) {
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) throw new Error("transcript scroller missing");
  const read = () => {
    const view = scroller.getBoundingClientRect();
    const mounted = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].map((row) => {
      const box = row.getBoundingClientRect();
      return { id: row.dataset.rowId!, y: box.top - view.top, bottom: box.bottom - view.top, height: box.height };
    });
    const visible = mounted.filter((row) => row.height > 0 && row.bottom > 0 && row.y < view.height);
    return { mounted: new Map(mounted.map((row) => [row.id, row])), visible };
  };
  let previous = read();
  const samples: UpwardAnchorFrame[] = [];
  let cancelledWheels = 0;
  const commands = [...steps, ...Array.from({ length: restFrames }, () => 0)];
  const driven = new Map<number, { asked: number; applied: number }>();
  let next = 0;
  // Keep the next callback registered before this frame's rendering. Sequential frame awaits
  // can miss an intermediate painted state while their posted task waits on a busy event loop.
  await new Promise<void>((resolve) => {
    window.cmuxAfterPaint(
      (paint) => {
        const command = driven.get(paint);
        if (!command) return;
        driven.delete(paint);
        const current = read();
        // Usually the previous first visible row. At a boundary, use the next row that the two
        // frames share; a missing anchor is evidence too, never a zero-drift sample.
        const anchor = previous.visible.find((row) => current.mounted.has(row.id));
        const top = current.visible[0];
        const rowBoxGaps = current.visible.flatMap((row, index, rows) => {
          const previous = rows[index - 1];
          if (!previous) return [];
          const gap = row.y - previous.bottom;
          return gap > 1 / 64 ? [{ gap, previous: previous.id, next: row.id }] : [];
        });
        const drift = anchor ? current.mounted.get(anchor.id)!.y - anchor.y + command.applied : null;
        samples.push({
          frame: samples.length,
          paint,
          topRowId: top?.id ?? null,
          topRowY: top?.y ?? null,
          requestedPixels: command.asked,
          wheelPixels: command.applied,
          scrollTop: scroller.scrollTop,
          anchorId: anchor?.id ?? null,
          drift,
          rowBoxGap: Math.max(0, ...rowBoxGaps.map((each) => each.gap)),
          rowBoxIds: rowBoxGaps.flatMap((each) => [each.previous, each.next]),
        });
        previous = current;
        if (samples.length === commands.length) {
          resolve();
          return false;
        }
      },
      (paint) => {
        if (next >= commands.length) return;
        const asked = commands[next++]!;
        let applied = 0;
        if (asked !== 0) {
          // A precise pixel wheel goes through the real reader-intent/cancellation handlers. A
          // synthetic event has no native default, so apply exactly that default here, recording
          // the clamped distance separately from any later layout/anchor scroll write.
          const wheel = new WheelEvent("wheel", { deltaY: asked, deltaMode: 0, bubbles: true, cancelable: true });
          if (scroller.dispatchEvent(wheel)) {
            const before = scroller.scrollTop;
            scroller.scrollTop = before + asked;
            applied = scroller.scrollTop - before;
          } else cancelledWheels += 1;
        }
        driven.set(paint, { asked, applied });
      },
    );
  });
  const compared = samples.filter((sample) => sample.drift !== null);
  return {
    frames: samples.length,
    compared: compared.length,
    missingAnchors: samples.length - compared.length,
    blankFrames: samples.filter((sample) => sample.topRowId === null).length,
    blankBandFrames: samples.filter((sample) => sample.rowBoxGap > 8).length,
    maxRowBoxGap: Math.max(0, ...samples.map((sample) => sample.rowBoxGap)),
    cancelledWheels,
    wheelPixels: samples.reduce((sum, sample) => sum + sample.wheelPixels, 0),
    maxDrift: Math.max(0, ...compared.map((sample) => Math.abs(sample.drift!))),
    totalDrift: compared.reduce((sum, sample) => sum + Math.abs(sample.drift!), 0),
    samples,
  };
}

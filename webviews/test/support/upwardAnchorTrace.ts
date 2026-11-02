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
  wheelGeometryPixels: number;
  rowBoxGap: number;
  expectedRowBoxGap: number;
  unexpectedRowBoxGap: number;
  missingRow: boolean;
  overlap: number;
  topEdgeGap: number;
  bottomEdgeGap: number;
  rowBoxIds: string[];
};

/** Runs in the page with paintedFrames installed; it deliberately closes over no test state. */
export async function traceUpwardAnchors({
  steps,
  restFrames = 24,
  foldStream = false,
}: {
  steps: number[];
  restFrames?: number;
  foldStream?: boolean;
}) {
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) throw new Error("transcript scroller missing");
  // Keep the oracle's spacing contract in the browser, next to the rendered boxes.  The
  // virtualizer uses these same grid tokens (transcriptGrid.ts); reading the computed values
  // avoids baking in an interface scale while still rejecting a gap that is merely close to a
  // token, or a gap in the wrong row pair.
  const transcriptMark = {
    other: 0,
    prompt: 1,
    message: 2,
    indicator: 3,
    footer: 4,
    step: 5,
    footerRow: 6,
    footerSlot: 7,
  } as const;

  function gridPx(name: string): number {
    const probe = document.createElement("span");
    probe.style.cssText = `position:absolute;width:var(${name});height:0;visibility:hidden`;
    document.body.append(probe);
    const value = Number.parseFloat(getComputedStyle(probe).width);
    probe.remove();
    return Number.isFinite(value) ? value : 0;
  }

  function markFor(row: HTMLElement): number | null {
    const kind = [...row.classList].find(
      (name) => name.startsWith("acpmux-") && !name.startsWith("acpmux-row"),
    );
    if (
      row.classList.contains("acpmux-row--line") ||
      row.classList.contains("acpmux-row--after-step") ||
      row.classList.contains("acpmux-row--before-step") ||
      kind === "acpmux-activity" ||
      kind === "acpmux-backgroundTask" ||
      kind === "acpmux-subagentDone" ||
      kind === "acpmux-compaction" ||
      kind === "acpmux-failover" ||
      kind === "acpmux-policyUnenforced" ||
      kind === "acpmux-agentPair" ||
      kind === "acpmux-sessionStart" ||
      kind === "acpmux-messageRun" ||
      kind === "acpmux-laneNoticeBatch" ||
      kind === "acpmux-pendingMessages"
    )
      return transcriptMark.step;
    if (kind === "acpmux-user")
      return row.querySelector(".cv-incoming, .cv-received, .acpmux-task-received")
        ? transcriptMark.other
        : transcriptMark.prompt;
    if (kind === "acpmux-assistant") return transcriptMark.message;
    if (kind === "acpmux-working" || kind === "acpmux-thinking" || kind === "acpmux-activityLine")
      return row.classList.contains("acpmux-row--below")
        ? transcriptMark.footerSlot
        : transcriptMark.indicator;
    if (kind === "acpmux-turnSummary") return transcriptMark.footer;
    return kind === undefined ? null : transcriptMark.other;
  }

  function expectedGap(
    previous: number | null,
    next: number | null,
    tokens: { footer: number; block: number; turn: number },
  ): number {
    if (previous === null || next === null) return 0;
    const { footer, block, turn } = tokens;
    if (
      (next === transcriptMark.footerRow || next === transcriptMark.footerSlot) &&
      previous === transcriptMark.message
    )
      return footer;
    if (
      (next === transcriptMark.indicator || next === transcriptMark.footerSlot) &&
      previous === transcriptMark.prompt
    )
      return block;
    if (previous === transcriptMark.prompt || next === transcriptMark.prompt) return turn;
    if (
      previous === transcriptMark.step &&
      (next === transcriptMark.step ||
        next === transcriptMark.indicator ||
        next === transcriptMark.footerSlot)
    )
      return 0;
    return block;
  }

  const gridTokens = {
    footer: gridPx("--grid-gap-footer"),
    block: gridPx("--grid-gap-block"),
    turn: gridPx("--grid-gap-turn"),
  };
  const read = () => {
    const view = scroller.getBoundingClientRect();
    const mounted = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].map((row) => {
      const box = row.getBoundingClientRect();
      return {
        index: Number(row.getAttribute("aria-posinset")) - 1,
        count: Number(row.getAttribute("aria-setsize")),
        id: row.dataset.rowId!,
        y: box.top - view.top,
        bottom: box.bottom - view.top,
        height: box.height,
        mark: markFor(row),
      };
    });
    const visible = mounted.filter(
      (row) => row.height > 0 && row.bottom > 0 && row.y < view.height,
    );
    return {
      mounted: new Map(mounted.map((row) => [row.id, row])),
      visible,
      viewHeight: view.height,
    };
  };
  const snapshotGeometry = (phase: string) => {
    const row = scroller.querySelector<HTMLElement>(`[data-row-id="${previous.visible[0]?.id}"]`);
    const thread = scroller.querySelector<HTMLElement>(".acpmux-thread");
    const view = scroller.getBoundingClientRect();
    return {
      phase,
      physical: scroller.scrollTop,
      rowId: row?.dataset.rowId,
      rowY: row ? row.getBoundingClientRect().top - view.top : undefined,
      rowTop: row?.style.top,
      rowMarginTop: row?.style.marginTop,
      threadY: thread ? thread.getBoundingClientRect().top - view.top : undefined,
      threadTop: thread?.style.top,
      origin: scroller.style.getPropertyValue("--acpmux-scroll-origin"),
    };
  };
  let previous = read();
  const synchronousBaseline = {
    geometry: snapshotGeometry("synchronous-baseline"),
    visible: previous.visible,
  };
  // The first comparison starts from a painted frame, like every later comparison. Keep the
  // synchronous sample as evidence: seeding/aria-setsize alone does not establish a paint.
  const firstPaintBaseline = await new Promise<{
    paint: number;
    geometry: unknown;
    visible: typeof previous.visible;
  }>((resolve) => {
    window.cmuxAfterPaint((paint) => {
      previous = read();
      resolve({
        paint,
        geometry: snapshotGeometry("first-paint-baseline"),
        visible: previous.visible,
      });
      return false;
    });
  });
  const baselineAnchor = synchronousBaseline.visible.find((row) => previous.mounted.has(row.id));
  const baselineDrift = baselineAnchor
    ? previous.mounted.get(baselineAnchor.id)!.y - baselineAnchor.y
    : null;
  const samples: UpwardAnchorFrame[] = [];
  let cancelledWheels = 0;
  let foldToggleClicks = 0;
  const foldTransitions: { before: string | null; after: string | null }[] = [];
  let pendingFold: string | null | undefined;
  const commands = [...steps, ...Array.from({ length: restFrames }, () => 0)];
  const driven = new Map<number, { asked: number; applied: number; geometry: number }>();
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
        if (pendingFold !== undefined) {
          const toggle = scroller.querySelector<HTMLButtonElement>(
            '[data-row-id="gap-incoming"] .cv-disclosure__toggle',
          );
          foldTransitions.push({
            before: pendingFold,
            after: toggle?.getAttribute("aria-expanded") ?? null,
          });
          pendingFold = undefined;
        }
        // Usually the previous first visible row. At a boundary, use the next row that the two
        // frames share; a missing anchor is evidence too, never a zero-drift sample.
        const anchor = previous.visible.find((row) => current.mounted.has(row.id));
        const top = current.visible[0];
        const bottom = current.visible.at(-1);
        // Only a transcript's true first/last row may leave intentional space at its ends.
        // Else row boxes must cover both viewport edges as well as every adjacent pair.
        const topEdgeGap = top ? (top.index > 0 ? Math.max(0, top.y) : 0) : current.viewHeight;
        const bottomEdgeGap =
          bottom && bottom.index < bottom.count - 1
            ? Math.max(0, current.viewHeight - bottom.bottom)
            : 0;
        const rowBoxGaps = current.visible.flatMap((row, index, rows) => {
          const previous = rows[index - 1];
          if (!previous) return [];
          const gap = row.y - previous.bottom;
          const expected = expectedGap(previous.mark, row.mark, gridTokens);
          return [{ gap, expected, previous: previous.id, next: row.id }];
        });
        const positiveGaps = rowBoxGaps.filter((each) => each.gap > 0);
        const unexpectedRowBoxGaps = rowBoxGaps.filter(
          (each) => Math.abs(each.gap - each.expected) > 1 / 64,
        );
        const missingRow = current.visible.some((row, index, rows) => {
          const previous = rows[index - 1];
          return previous !== undefined && row.index > previous.index + 1;
        });
        const drift = anchor
          ? current.mounted.get(anchor.id)!.y - anchor.y + command.applied
          : null;
        samples.push({
          frame: samples.length,
          paint,
          topRowId: top?.id ?? null,
          topRowY: top?.y ?? null,
          requestedPixels: command.asked,
          wheelPixels: command.applied,
          wheelGeometryPixels: command.geometry,
          scrollTop: scroller.scrollTop,
          anchorId: anchor?.id ?? null,
          drift,
          rowBoxGap: Math.max(0, ...positiveGaps.map((each) => each.gap)),
          expectedRowBoxGap: Math.max(0, ...rowBoxGaps.map((each) => each.expected)),
          unexpectedRowBoxGap: Math.max(
            0,
            ...unexpectedRowBoxGaps.map((each) => Math.abs(each.gap - each.expected)),
          ),
          missingRow,
          overlap: Math.max(0, ...rowBoxGaps.map((each) => -each.gap)),
          topEdgeGap,
          bottomEdgeGap,
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
        const frame = next;
        const asked = commands[next++]!;
        if (foldStream) {
          (window as unknown as { __stepFoldStream(): void }).__stepFoldStream();
          if ([4, 32, 60, 88].includes(frame)) {
            const toggle = scroller.querySelector<HTMLButtonElement>(
              '[data-row-id="gap-incoming"] .cv-disclosure__toggle',
            );
            if (!toggle) throw new Error(`received fold toggle missing at frame ${frame}`);
            pendingFold = toggle.getAttribute("aria-expanded");
            toggle.click();
            foldToggleClicks += 1;
          }
        }
        let applied = 0;
        let geometry = 0;
        if (asked !== 0) {
          // A precise pixel wheel goes through the real reader-intent/cancellation handlers. A
          // synthetic event has no native default, so apply exactly that default here, recording
          // the clamped distance separately from any later layout/anchor scroll write.
          const wheel = new WheelEvent("wheel", {
            deltaY: asked,
            deltaMode: 0,
            bubbles: true,
            cancelable: true,
          });
          if (scroller.dispatchEvent(wheel)) {
            const before = scroller.scrollTop;
            const probe = scroller.querySelector<HTMLElement>(".acpmux-row");
            const beforeY = probe?.getBoundingClientRect().top;
            scroller.scrollTop = before + asked;
            applied = scroller.scrollTop - before;
            geometry =
              probe && beforeY !== undefined
                ? beforeY - probe.getBoundingClientRect().top
                : applied;
          } else cancelledWheels += 1;
        }
        driven.set(paint, { asked, applied, geometry });
      },
    );
  });
  const compared = samples.filter((sample) => sample.drift !== null);
  return {
    synchronousBaseline,
    firstPaintBaseline,
    baselineAnchorId: baselineAnchor?.id ?? null,
    baselineDrift,
    frames: samples.length,
    compared: compared.length,
    missingAnchors: samples.length - compared.length,
    blankFrames: samples.filter((sample) => sample.topRowId === null).length,
    blankBandFrames: samples.filter(
      (sample) => sample.unexpectedRowBoxGap > 1 / 64 || sample.missingRow,
    ).length,
    unexpectedRowBoxFrames: samples.filter((sample) => sample.unexpectedRowBoxGap > 1 / 64).length,
    missingRowFrames: samples.filter((sample) => sample.missingRow).length,
    overlapFrames: samples.filter((sample) => sample.overlap > 1 / 64).length,
    maxRowBoxGap: Math.max(0, ...samples.map((sample) => sample.rowBoxGap)),
    maxExpectedRowBoxGap: Math.max(0, ...samples.map((sample) => sample.expectedRowBoxGap)),
    maxUnexpectedRowBoxGap: Math.max(0, ...samples.map((sample) => sample.unexpectedRowBoxGap)),
    blankEdgeFrames: samples.filter(
      (sample) => Math.max(sample.topEdgeGap, sample.bottomEdgeGap) > 8,
    ).length,
    maxViewportEdgeGap: Math.max(
      0,
      ...samples.flatMap((sample) => [sample.topEdgeGap, sample.bottomEdgeGap]),
    ),
    cancelledWheels,
    foldToggleClicks,
    foldTransitions,
    wheelPixels: samples.reduce((sum, sample) => sum + sample.wheelPixels, 0),
    maxImmediateReadbackError: Math.max(
      0,
      ...samples.map((sample) => Math.abs(sample.wheelGeometryPixels - sample.wheelPixels)),
    ),
    maxDrift: Math.max(0, ...compared.map((sample) => Math.abs(sample.drift!))),
    totalDrift: compared.reduce((sum, sample) => sum + Math.abs(sample.drift!), 0),
    samples,
  };
}

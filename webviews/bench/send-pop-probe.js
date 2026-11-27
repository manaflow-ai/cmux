// l10n-allow-file: bench fixture prompts, not shipped UI.
// The page half of the sent-prompt pop's attachment checks (conversation.css SEND-POP; Leo 2026-11-22: "oh you
// better probably also watch that attachments and such are good too when the pop is there"). One expression that
// installs `window.__sendPopProbe`, evaluated as is in the production pane (Playwright, bench/send-pop-cases.ts) and
// in a tagged app's agent chat page (DevTools Runtime.evaluate, scripts/measure/send-pop-films.py), so both read the
// same checks:
//   attach({images, file, pastedText, text})  pastes the case's attachments into the composer through the page's own
//                                             paste path (a ClipboardEvent, as Cmd-V delivers one), and, with `text`
//                                             (multi-line), a paste of that text
//   arm(marker)                               every frame from now: the newest sent prompt holding `marker`, its
//                                             bubble, each attachment in it, the transcript's scroll and the frame time
//   result()                                  stops and judges (below); call it 1.5 s or more after the Return
// The judged facts, per send:
//   unit         every attachment's box scales with its bubble's on every frame of the pop (ratio within 1%), and
//                sits inside the bubble's presentation wrapper, so the two are one transform
//   lateness     every attachment and every picture is drawn (img.complete with pixels) from the row's first frame
//   clipping     no attachment's box passes a clipping ancestor's box during the scale (px over, the most)
//   reflow       each attachment's place in its bubble on the first frame after the pop equals its place at the end (px)
//   heightJump   no attachment's height changes during the pop but by the bubble's scale (a late decode would)
//   scroll       at the end the sent prompt is in view and the transcript is at its foot (px from it)
//   frames       p50 and p95 frame gaps over the Return to 600 ms after, and dropped frames there
(() => {
  const FIELD = ".acpmux-composer-prompt [contenteditable='true'], .ProseMirror.acpmux-md[contenteditable='true']";
  const ATTACHMENTS = "img, .acpmux-attachment, .acpmux-file-chip, .acpmux-paste-chip";
  const VSYNC = 1000 / 60;
  // A picture: `size` [width, height]; `noise` fills it with random pixels, which compress badly and decode slowly,
  // so a sent copy can still be decoding when its pop starts.
  const canvasFile = async (index, size = [1600 + index * 200, 1000], noise = false) => {
    const canvas = document.createElement("canvas");
    [canvas.width, canvas.height] = size;
    const context = canvas.getContext("2d");
    if (noise) {
      const pixels = context.createImageData(canvas.width, canvas.height);
      const words = new Uint32Array(pixels.data.buffer);
      for (let at = 0; at < words.length; at++) words[at] = (Math.random() * 0xffffffff) | 0xff000000;
      context.putImageData(pixels, 0, 0);
    } else {
      context.fillStyle = ["#3a7bd5", "#d5573a", "#3ad58a", "#a03ad5"][index % 4]; // colour-allow: fixture pixels
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = "#f2f4f8"; // colour-allow: fixture pixels
      context.fillRect(100, 100, canvas.width - 200, 140);
    }
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
    return new File([blob], `Screenshot ${index + 1}.png`, { type: "image/png" });
  };
  const paste = (data) => {
    const field = document.querySelector(FIELD);
    if (!field) throw new Error("no composer field");
    field.focus();
    field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  };
  const quantile = (values, q) => {
    const sorted = [...values].sort((a, b) => a - b);
    return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * (sorted.length - 1)))] : 0;
  };
  const outermost = (elements) =>
    elements.filter((el) => !elements.some((other) => other !== el && other.contains(el)));
  const box = (el) => {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, w: r.width, h: r.height };
  };
  const scroller = (el) => {
    for (let node = el.parentElement; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (/(auto|scroll)/.test(style.overflowY) && node.scrollHeight > node.clientHeight) return node;
    }
    return document.scrollingElement;
  };
  // The boxes that clip an attachment inside the transcript: the scroller itself (a tall prompt scrolled past its
  // edge is not clipped by the pop) and what holds it are left out.
  const clippers = (el, stop) => {
    const found = [];
    for (let node = el.parentElement; node && node !== stop; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (
        style.overflowX !== "visible" ||
        style.overflowY !== "visible" ||
        style.clipPath !== "none" ||
        style.contain.includes("paint")
      )
        found.push(node);
    }
    return found;
  };
  const state = { frames: [], rows: [], running: false };

  window.__sendPopProbe = {
    async attach({ images = 0, tall = false, decoding = false, file = false, pastedText = 0, text = "" } = {}) {
      const data = new DataTransfer();
      for (let index = 0; index < images; index++) data.items.add(await canvasFile(index));
      // A very tall picture (a full-page screenshot), and one still decoding when the pop starts.
      if (tall) data.items.add(await canvasFile(images, [900, 6000]));
      if (decoding) data.items.add(await canvasFile(images + 1, [6000, 4000], true));
      if (file) data.items.add(new File(["name,value\nsend-pop,1\n".repeat(40)], "results.csv", { type: "text/csv" }));
      if (data.items.length) {
        paste(data);
        await new Promise((resolve) => setTimeout(resolve, 900));
      }
      if (pastedText) {
        const words = Array.from({ length: pastedText }, (_, index) => `word${index % 97}`).join(" ");
        const big = new DataTransfer();
        big.setData("text/plain", words.replace(/((?:\S+ ){12})/g, "$1\n"));
        paste(big);
        await new Promise((resolve) => setTimeout(resolve, 600));
      }
      if (text) {
        const typed = new DataTransfer();
        typed.setData("text/plain", text);
        paste(typed);
        await new Promise((resolve) => setTimeout(resolve, 300));
      }
      const composer = document.querySelector(".acpmux-composer") ?? document.body;
      return {
        composerAttachments: outermost([...composer.querySelectorAll(ATTACHMENTS)]).length,
        fieldChars: document.querySelector(FIELD)?.textContent?.length ?? 0,
      };
    },

    arm(marker) {
      state.frames = [];
      state.rows = [];
      state.running = true;
      state.marker = marker;
      state.armedAt = performance.now();
      state.sentAt = undefined;
      state.clip = undefined;
      const frame = (now) => {
        if (!state.running) return;
        state.frames.push(now);
        const rows = [...document.querySelectorAll(".acpmux-row.acpmux-user")].filter((row) =>
          (row.textContent ?? "").includes(marker),
        );
        const row = rows.at(-1);
        const presentation = row?.querySelector(".acpmux-row__message-presentation");
        if (row && presentation) {
          state.sentAt ??= now;
          const attachments = outermost([...row.querySelectorAll(ATTACHMENTS)]);
          const scroll = scroller(row);
          state.clip ??= attachments.map((el) => clippers(el, scroll));
          const animation = presentation.getAnimations().find((a) => a.animationName?.startsWith("cv-send-pop"));
          const view = scroll.getBoundingClientRect();
          const rowBox = row.getBoundingClientRect();
          state.rows.push({
            at: now,
            popMs: animation ? Number(animation.currentTime ?? 0) : null,
            bubble: box(presentation),
            inside: attachments.map((el) => presentation.contains(el)),
            attachments: attachments.map(box),
            drawn: attachments.map((el) => {
              const pictures = el.tagName === "IMG" ? [el] : [...el.querySelectorAll("img")];
              return (
                pictures.every((img) => img.complete && img.naturalWidth > 0) && el.getBoundingClientRect().width > 0
              );
            }),
            clipped: attachments.map((el, index) => {
              const r = el.getBoundingClientRect();
              let over = 0;
              for (const clipper of state.clip[index] ?? []) {
                const c = clipper.getBoundingClientRect();
                over = Math.max(over, c.left - r.left, r.right - c.right, c.top - r.top, r.bottom - c.bottom);
              }
              return Math.max(0, over);
            }),
            foot: scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight,
            // In view: its foot shows, and its top too unless it is taller than the transcript.
            inView: rowBox.bottom <= view.bottom + 1 && (rowBox.top >= view.top - 1 || rowBox.height > view.height),
            rowBottomToView: view.bottom - rowBox.bottom,
          });
        }
        requestAnimationFrame(frame);
      };
      requestAnimationFrame(frame);
      return true;
    },

    result() {
      state.running = false;
      const rows = state.rows;
      if (!rows.length) return { error: `no sent prompt holding ${state.marker} drew`, frames: state.frames.length };
      const first = rows[0];
      const last = rows.at(-1);
      const count = last.attachments.length;
      const restBubble = last.bubble;
      // The unit check: an attachment's width over its rest width against the bubble's, every frame of the pop.
      let unitWorst = 0;
      for (const row of rows) {
        if (row.attachments.length !== count) continue;
        const bubbleScale = row.bubble.w / restBubble.w;
        row.attachments.forEach((a, index) => {
          const rest = last.attachments[index];
          if (rest.w > 0) unitWorst = Math.max(unitWorst, Math.abs(a.w / rest.w - bubbleScale));
        });
      }
      // A size that arrives mid-pop (a picture that decodes late): each attachment's height against its rest
      // height times the bubble's scale, every frame; a uniform scale keeps it 0.
      let heightJump = 0;
      for (const row of rows) {
        if (row.attachments.length !== count) continue;
        const bubbleScale = row.bubble.w / restBubble.w;
        row.attachments.forEach((a, index) => {
          heightJump = Math.max(heightJump, Math.abs(a.h - last.attachments[index].h * bubbleScale));
        });
      }
      const popped = rows.filter((row) => row.popMs !== null);
      // The first frame after the pop ended (it starts on its first drawn frame, entranceClock.ts, so not a fixed
      // time after the row came) against the end: each attachment's place in its bubble.
      const lastPop = rows.findLastIndex((row) => row.popMs !== null);
      const settled = rows[lastPop + 1] ?? last;
      let reflow = 0;
      settled.attachments.forEach((a, index) => {
        const end = last.attachments[index];
        if (!end) return;
        reflow = Math.max(
          reflow,
          Math.abs(a.x - settled.bubble.x - (end.x - last.bubble.x)),
          Math.abs(a.y - settled.bubble.y - (end.y - last.bubble.y)),
          Math.abs(a.w - end.w),
          Math.abs(a.h - end.h),
        );
      });
      const span = state.frames.filter((at) => at >= state.sentAt - 50 && at <= state.sentAt + 600);
      const gaps = span.slice(1).map((at, index) => at - span[index]);
      return {
        attachments: count,
        attachmentsAtFirstFrame: first.attachments.length,
        allInsideWrapper: rows.every((row) => row.inside.every(Boolean)),
        unitWorst: Number(unitWorst.toFixed(4)),
        popFrames: popped.length,
        popRan: popped.length > 0,
        firstFrameDrawn: first.drawn.every(Boolean),
        lateDrawFrames: rows.filter((row) => !row.drawn.every(Boolean)).length,
        clippedPx: Number(Math.max(0, ...rows.flatMap((row) => row.clipped)).toFixed(2)),
        reflowPx: Number(reflow.toFixed(2)),
        heightJumpPx: Number(heightJump.toFixed(2)),
        // After the pop, the last frame in which an attachment's box in its bubble changed by over 0.5 px, and how.
        settleMove: (() => {
          let move = null;
          for (let index = 1; index < rows.length; index++) {
            const [before, now] = [rows[index - 1], rows[index]];
            if (now.at <= settled.at || now.attachments.length !== before.attachments.length) continue;
            now.attachments.forEach((a, k) => {
              const b = before.attachments[k];
              const d = {
                dx: a.x - now.bubble.x - (b.x - before.bubble.x),
                dy: a.y - now.bubble.y - (b.y - before.bubble.y),
                dw: a.w - b.w,
                dh: a.h - b.h,
                bw: now.bubble.w - before.bubble.w,
                bh: now.bubble.h - before.bubble.h,
              };
              if (Object.values(d).some((v) => Math.abs(v) > 0.5))
                move = {
                  ms: Math.round(now.at - state.sentAt),
                  ...Object.fromEntries(Object.entries(d).map(([key, v]) => [key, Number(v.toFixed(2))])),
                };
            });
          }
          return move;
        })(),
        endFootPx: Math.round(last.foot),
        endInView: last.inView,
        endRowBottomToViewPx: Math.round(last.rowBottomToView),
        frameP50: Number(quantile(gaps, 0.5).toFixed(2)),
        frameP95: Number(quantile(gaps, 0.95).toFixed(2)),
        dropped: gaps.reduce((total, gap) => total + Math.max(0, Math.round(gap / VSYNC) - 1), 0),
        frames: span.length,
        bubbleScaleFirst: Number((first.bubble.w / restBubble.w).toFixed(4)),
      };
    },
  };
  return true;
})();

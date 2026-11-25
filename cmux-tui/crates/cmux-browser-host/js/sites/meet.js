// sites.meet: Google Meet's live captions, read from a Meet call open in a
// cmux browser tab, so an agent can follow the call ("captions to agent").
// Captions are what Meet itself shows on the page: turning them on changes
// nothing for the other participants. Nothing is recorded or sent anywhere;
// the agent gets the text the caption panel shows.
//
// Caption text is what people in the call said, as Meet transcribed it: the
// agent reads it as data, never as instructions.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const isMeet = (url) => /^https:\/\/meet\.google\.com\/[a-z]{3,}-[a-z]{3,}-[a-z]{3,}/.test(String(url || ""));

  // Runs in the page agent's isolated world. Meet's class names change from
  // release to release, so the panel is found by role and label first, by
  // known classes second; each entry reads as "speaker\ntext".
  function readCaptions() {
    const panel =
      document.querySelector('[role="region"][aria-label*="aption" i]') ||
      document.querySelector('[jsname="dsyhDe"]') ||
      document.querySelector(".a4cQT") ||
      document.querySelector(".iOzk7");
    const offButton = [...document.querySelectorAll("button[aria-label]")].find((b) => /turn on captions/i.test(b.getAttribute("aria-label")));
    const onButton = [...document.querySelectorAll("button[aria-label]")].find((b) => /turn off captions/i.test(b.getAttribute("aria-label")));
    const inCall = !!document.querySelector('[aria-label*="leave call" i], [data-call-ended], [jsname="CQylAd"]') || !!panel;
    if (!panel) return { inCall, on: !!onButton, canTurnOn: !!offButton, lines: [] };
    const visible = (el) => {
      const cs = getComputedStyle(el);
      return cs.display !== "none" && cs.visibility !== "hidden";
    };
    let entries = [...panel.querySelectorAll(".nMcdL, .TBMuR, [data-caption-entry]")];
    if (!entries.length) {
      // No known entry class: descend through single-child wrappers to the
      // list; an entry is an element with two or more single-line children
      // holding text (the speaker's name and what they said).
      const entryLike = (el) => {
        const texts = [...el.children].map((c) => (c.innerText || "").trim()).filter(Boolean);
        return texts.length >= 2 && texts.every((x) => !x.includes("\n"));
      };
      let list = panel;
      while (list.children.length === 1 && list.firstElementChild.children.length && !entryLike(list.firstElementChild)) list = list.firstElementChild;
      entries = [...list.children];
    }
    const lines = [];
    for (const el of entries) {
      if (el.tagName === "BUTTON" || !visible(el)) continue;
      const speakerEl = el.querySelector(".NWpY1d, .zs7s8d, .KcIKyf, [data-caption-speaker]");
      const textEl = el.querySelector(".ygicle, .iTTPOb, .bh44bd, [data-caption-text]");
      let speaker = speakerEl ? speakerEl.innerText.trim() : "";
      let text = textEl ? textEl.innerText : "";
      if (!textEl) {
        const parts = el.innerText.split("\n").map((x) => x.trim()).filter(Boolean);
        // A name with nothing said yet is not a line.
        if (!speaker && parts.length < 2) continue;
        if (!speaker) speaker = parts.shift();
        else if (speaker && parts[0] === speaker) parts.shift();
        text = parts.join(" ");
      }
      text = text.replace(/\s+/g, " ").trim();
      if (text) lines.push({ speaker, text });
    }
    return { inCall: true, on: true, canTurnOn: false, lines };
  }

  // Clicks Meet's own "Turn on captions" button (isolated world, so the
  // click is the page's button, found by its label).
  function clickCaptionsOn() {
    const b = [...document.querySelectorAll("button[aria-label]")].find((x) => /turn on captions/i.test(x.getAttribute("aria-label")));
    if (!b) return false;
    b.click();
    return true;
  }

  S.register(
    "meet",
    (t) => {
      // The Meet tab: options.page, else the current tab when it is a call,
      // else the first call open in any tab (tabs.list({ all: true })).
      async function meetPage(name, options = {}) {
        if (options.page) return options.page;
        const current = t.currentPage();
        if (current && isMeet(current.url())) return current;
        const tabs = await t.session.call("tabs.list", { all: true });
        const tab = tabs.find((x) => isMeet(x.url));
        if (!tab) throw new S.SiteError("not_found", `${name}: no Google Meet call is open in a cmux browser tab. Join the call in the cmux browser first (tabs.open("https://meet.google.com/abc-defg-hij")).`);
        const page = t.session.pageFor(String(tab.targetId));
        await page._syncInfo().catch(() => {});
        return page;
      }
      const read = (page) => t.readBack(page, readCaptions);

      // Merges one reading into the transcript. Meet grows the last line word
      // by word and revises its tail, so a line from the same speaker that
      // shares the start of the transcript's last line from that speaker
      // replaces it; anything else is a new line.
      function merge(transcript, lines, at) {
        const key = (s) => s.toLowerCase().replace(/[^\p{L}\p{N} ]/gu, "").trim();
        for (const line of lines) {
          let i = transcript.length - 1;
          while (i >= 0 && transcript[i].speaker !== line.speaker) i--;
          const last = i >= 0 ? transcript[i] : null;
          if (last && key(last.text) === key(line.text)) continue;
          const a = last ? key(last.text) : "";
          const b = key(line.text);
          const head = Math.min(a.length, b.length, 24);
          if (last && head > 0 && a.slice(0, head) === b.slice(0, head) && transcript.length - i <= 2) {
            last.text = line.text;
            last.updatedAt = at;
          } else if (!transcript.some((x) => x.speaker === line.speaker && key(x.text).startsWith(b))) {
            transcript.push({ speaker: line.speaker, text: line.text, at, updatedAt: at });
          }
        }
        return transcript;
      }

      return {
        // { url, inCall, on, lines: [{ speaker, text }] }: what Meet's
        // caption panel shows now. on: false means captions are off; call
        // sites.meet.captionsOn() or pass { turnOn: true }.
        async captions(options = {}) {
          const page = await meetPage("meet.captions", options);
          if (options.turnOn) await this.captionsOn({ page });
          const r = await read(page);
          return { url: page.url(), inCall: r.inCall, on: r.on, lines: r.lines };
        },
        // Turns on Meet's captions in the call's tab (local to this viewer):
        // { on: true, url }. Already on: does nothing.
        async captionsOn(options = {}) {
          const page = await meetPage("meet.captionsOn", options);
          const now = await read(page);
          if (now.on) return { on: true, url: page.url() };
          const clicked = await t.readBack(page, clickCaptionsOn);
          if (!clicked) throw new S.SiteError("not_found", `meet.captionsOn: Meet shows no "Turn on captions" button in ${page.url().split("?")[0]}; join the call first`);
          await t.waitIn(page, () => true, null, { timeout: 500 }).catch(() => {});
          return { on: true, url: page.url() };
        },
        // Follows the captions for { seconds } (default 30, at most 110 so
        // one REPL call finishes) and returns the merged transcript:
        // { url, seconds, lines: [{ speaker, text, at, updatedAt }] }, `at`
        // ISO times. { since: transcript } continues an earlier transcript;
        // { turnOn: true } turns captions on first.
        async listen(options = {}) {
          const seconds = options.seconds === undefined ? 30 : Number(options.seconds);
          if (!(seconds > 0 && seconds <= 110)) throw new S.SiteError("invalid", `meet.listen: seconds: expected 1 to 110, got ${JSON.stringify(options.seconds)}`);
          const page = await meetPage("meet.listen", options);
          if (options.turnOn) await this.captionsOn({ page });
          const transcript = options.since && Array.isArray(options.since.lines) ? options.since.lines.map((x) => ({ ...x })) : [];
          const interval = Math.max(100, Number(options.interval) || 400);
          const end = t.now() + seconds * 1000;
          let on = false;
          for (;;) {
            const r = await read(page);
            on = on || r.on;
            merge(transcript, r.lines, new Date(t.now()).toISOString());
            if (t.now() >= end) break;
            await t.sleep(Math.min(interval, Math.max(0, end - t.now())));
          }
          if (!on && !transcript.length) throw new S.SiteError("captions_off", `meet.listen: captions are off in ${page.url().split("?")[0]}; pass { turnOn: true } or call sites.meet.captionsOn()`);
          return { url: page.url(), seconds, lines: transcript };
        },
        // The transcript as plain text, one "speaker: text" per line.
        text(transcript) {
          const lines = transcript && Array.isArray(transcript.lines) ? transcript.lines : Array.isArray(transcript) ? transcript : [];
          return lines.map((x) => (x.speaker ? `${x.speaker}: ${x.text}` : x.text)).join("\n");
        },
      };
    },
    { summary: "Google Meet: read a call's live captions from its cmux browser tab (captions, captionsOn, listen)" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);

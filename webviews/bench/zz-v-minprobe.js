(() => {
  let on = 0, all = 0, passes = 0, lastActive = false;
  setInterval(() => {
    all++;
    if (document.querySelector('[data-chat-motion="minimal"]')) on++;
    const a = !!document.querySelector(".is-shimmer-active");
    if (a && !lastActive) passes++;
    lastActive = a;
  }, 50);
  window.__probe = () => ({ minimal_frac: all ? +(on / all).toFixed(3) : null, samples: all, passes });
})();

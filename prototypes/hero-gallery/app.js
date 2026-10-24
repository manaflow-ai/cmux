const variants = {
  focus: {
    kicker: "surface 01 / focus",
    title: "Make every pane<br /><span>intentional.</span>",
    description: "A calm launch surface for the moment before work starts. The preview gives the next action a place to land.",
    primary: "Open focus surface",
    label: "focus / ready",
    titleBar: "morning / workspace",
    status: "3 panes ready",
    caption: "anchored preview / pointer-aware",
    body: `<div class="focus-grid"><div class="pane-list"><div class="pane-list-label">workspace</div><div class="pane-list-items"><div class="pane-item is-selected"><i></i>morning</div><div class="pane-item"><i></i>review</div><div class="pane-item"><i></i>scratch</div></div></div><div class="pane-main"><div class="pane-main-label">active pane / terminal</div><div class="command-line"><strong>›</strong> cmux open --workspace morning<span class="command-caret"></span></div><div class="pane-main-foot"><span>local / ready</span><span>3 panes / 1 tab</span></div></div></div>`,
  },
  cloud: {
    kicker: "surface 02 / cloud",
    title: "Warm the path<br /><span>before the work.</span>",
    description: "A visible route from request to ready machine. Each step stays anchored so latency has a shape.",
    primary: "Route a workspace",
    label: "cloud / route",
    titleBar: "fleet / west coast",
    status: "2 machines warm",
    caption: "route rail / latency made visible",
    body: `<div class="cloud-layout"><div class="route-rail"><div class="route-step is-active"><i>01</i><span><strong>route</strong><small>us-west1 / 42 ms</small></span></div><div class="route-step"><i>02</i><span><strong>warm</strong><small>machine image / 1.2 s</small></span></div><div class="route-step"><i>03</i><span><strong>ready</strong><small>workspace / attached</small></span></div></div><div class="cloud-map"><div class="cloud-path" aria-hidden="true"></div><div class="cloud-node node-a is-active"><strong>edge / pdx</strong><small>42 ms · routing</small></div><div class="cloud-node node-b"><strong>vm / 02</strong><small>warming · 61%</small></div><div class="cloud-node node-c"><strong>workspace</strong><small>waiting for attach</small></div></div></div>`,
  },
  agent: {
    kicker: "surface 03 / agent",
    title: "Keep the work<br /><span>in sequence.</span>",
    description: "A queue that exposes what is happening now, what comes next, and where a person can take over.",
    primary: "Open agent queue",
    label: "agent / 02 of 03",
    titleBar: "agent / queue",
    status: "1 active · 2 next",
    caption: "bounded timeline / resumable",
    body: `<div class="agent-layout"><div class="agent-timeline"><div class="timeline-head"><strong>handoff sequence</strong><span>02 / 03</span></div><div class="timeline-track"><div class="timeline-row is-done"><i class="timeline-dot"></i><span><strong>inspect</strong><small>diff is ready for review</small></span><span class="timeline-time">done</span></div><div class="timeline-row is-current"><i class="timeline-dot"></i><span><strong>compose</strong><small>agent is writing the patch</small></span><span class="timeline-time">now</span></div><div class="timeline-row"><i class="timeline-dot"></i><span><strong>handoff</strong><small>person chooses what lands</small></span><span class="timeline-time">next</span></div></div></div><div class="agent-note"><span class="agent-note-label">agent note</span><blockquote>“I found one surface boundary. <span>Want the small patch or the full pass?</span>”</blockquote><span class="agent-note-footer">esc to pause · enter to accept</span></div></div>`,
  },
};

const body = document.body;
const shell = document.querySelector("#preview-shell");
const previewBody = document.querySelector("#preview-body");
const pointerGlow = document.querySelector("#pointer-glow");
const palette = document.querySelector("#command-palette");
const paletteBackdrop = document.querySelector("#palette-backdrop");
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
let currentVariant = "focus";
let sequenceTimers = [];
let pointerFrame = 0;
let pendingPointer = null;
let hoverStartedAt = 0;

function announce(message) {
  document.querySelector("#metrics-last").textContent = message;
}

function clearSequence() {
  sequenceTimers.forEach((timer) => window.clearTimeout(timer));
  sequenceTimers = [];
  shell.classList.remove("is-sequencing");
}

function setTabRule(target) {
  const active = document.querySelector(`.variant-tab[data-variant="${target}"]`);
  const rule = document.querySelector(".tab-rule i");
  if (!active || !rule) return;
  rule.style.width = `${active.getBoundingClientRect().width}px`;
  rule.style.transform = `translateX(${active.offsetLeft}px)`;
}

function renderVariant(name, { announceChange = true } = {}) {
  const variant = variants[name];
  if (!variant) return;
  clearSequence();
  currentVariant = name;
  body.dataset.variant = name;
  document.querySelector("#variant-kicker").textContent = variant.kicker;
  document.querySelector("#hero-title").innerHTML = variant.title;
  document.querySelector("#hero-description").textContent = variant.description;
  document.querySelector("#primary-label").textContent = variant.primary;
  document.querySelector("#surface-label").textContent = variant.label;
  document.querySelector("#preview-title").textContent = variant.titleBar;
  document.querySelector("#preview-status").textContent = variant.status;
  document.querySelector("#surface-caption").firstChild.textContent = variant.caption;
  previewBody.innerHTML = variant.body;
  document.querySelectorAll(".variant-tab").forEach((tab) => {
    const isActive = tab.dataset.variant === name;
    tab.classList.toggle("is-active", isActive);
    tab.setAttribute("aria-selected", String(isActive));
  });
  requestAnimationFrame(() => setTabRule(name));
  if (announceChange) announce(`${variant.kicker} selected · ${variant.status}`);
}

function runSequence() {
  clearSequence();
  const start = performance.now();
  shell.classList.add("is-sequencing");
  announce("sequence started · bounded at 3 stages");
  const steps = [...previewBody.querySelectorAll(".route-step, .timeline-row")];
  if (steps.length) {
    steps.forEach((step, index) => {
      step.style.opacity = index === 0 ? "1" : "0.42";
      sequenceTimers.push(window.setTimeout(() => {
        steps.forEach((item, itemIndex) => item.classList.toggle("is-active", itemIndex === index));
        step.style.animation = reducedMotion.matches ? "none" : "stage-step var(--stage-step) cubic-bezier(0.22, 1, 0.36, 1) both";
        announce(`stage ${index + 1} of ${steps.length} · ${Math.round(performance.now() - start)} ms`);
      }, reducedMotion.matches ? 0 : index * 340));
    });
  }
  sequenceTimers.push(window.setTimeout(() => {
    shell.classList.remove("is-sequencing");
    announce(`sequence complete · ${Math.round(performance.now() - start)} ms`);
    sequenceTimers = [];
  }, reducedMotion.matches ? 1 : Math.max(steps.length, 1) * 340 + 180));
}

function openPalette() {
  palette.hidden = false;
  paletteBackdrop.hidden = false;
  requestAnimationFrame(() => palette.classList.add("is-open"));
  palette.querySelector(".palette-option")?.focus();
  announce("command surface open · choose a destination");
}

function closePalette() {
  palette.classList.remove("is-open");
  window.setTimeout(() => {
    palette.hidden = true;
    paletteBackdrop.hidden = true;
  }, reducedMotion.matches ? 1 : 180);
  document.querySelector("#primary-action")?.focus();
  announce("command surface closed · ready");
}

document.querySelectorAll(".variant-tab").forEach((tab) => tab.addEventListener("click", () => renderVariant(tab.dataset.variant)));
document.querySelector("#sequence-action").addEventListener("click", runSequence);
document.querySelector("#primary-action").addEventListener("click", openPalette);
document.querySelector("#palette-close").addEventListener("click", closePalette);
paletteBackdrop.addEventListener("click", closePalette);
document.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") { event.preventDefault(); openPalette(); }
  if (event.key === "Escape" && !palette.hidden) closePalette();
});
document.querySelectorAll(".palette-option").forEach((option) => option.addEventListener("click", () => {
  document.querySelector("#preview-title").textContent = option.dataset.destination;
  closePalette();
  announce(`destination selected · ${option.dataset.destination}`);
}));

shell.addEventListener("pointerenter", (event) => {
  hoverStartedAt = performance.now();
  pendingPointer = { x: event.clientX, y: event.clientY };
});
shell.addEventListener("pointermove", (event) => {
  pendingPointer = { x: event.clientX, y: event.clientY };
  if (pointerFrame) return;
  pointerFrame = requestAnimationFrame(() => {
    pointerFrame = 0;
    if (!pendingPointer) return;
    const rect = shell.getBoundingClientRect();
    pointerGlow.style.left = `${pendingPointer.x - rect.left}px`;
    pointerGlow.style.top = `${pendingPointer.y - rect.top}px`;
    pointerGlow.style.opacity = "1";
  });
});
shell.addEventListener("pointerleave", () => {
  if (pointerFrame) cancelAnimationFrame(pointerFrame);
  pointerFrame = 0;
  pendingPointer = null;
  pointerGlow.style.opacity = "0";
  if (hoverStartedAt) announce(`peek-open settled · ${Math.round(performance.now() - hoverStartedAt)} ms`);
});

window.addEventListener("resize", () => setTabRule(currentVariant));
window.addEventListener("beforeunload", clearSequence);
renderVariant("focus", { announceChange: false });

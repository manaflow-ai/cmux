"use client";

import { useState, useEffect, useRef, useCallback, useSyncExternalStore } from "react";

type DevValues = {
  headerTx: number;
  cursorTop: number;
  cursorBlink: boolean;
  subtitleLh: number;
  downloadAbove: number;
  downloadBelow: number;
  featuresLh: number;
  featuresPt: number;
  featuresPb: number;
  communityGap: number;
  faqPt: number;
  docsPt: number;
};

const defaults: DevValues = {
  headerTx: -4,
  cursorTop: 2.5,
  cursorBlink: true,
  subtitleLh: 1.5,
  downloadAbove: 21,
  downloadBelow: 16,
  featuresLh: 1.275,
  featuresPt: 12,
  featuresPb: 15,
  communityGap: 16,
  faqPt: 0,
  docsPt: 8,
};

// Tiny external store (avoids setState-during-render)
let snapshot = { ...defaults };
const listeners = new Set<() => void>();

function getSnapshot() { return snapshot; }
function getServerSnapshot() { return defaults; }

function setStore(patch: Partial<DevValues>) {
  snapshot = { ...snapshot, ...patch };
  listeners.forEach((l) => l());
}

function subscribe(cb: () => void) {
  listeners.add(cb);
  return () => { listeners.delete(cb); };
}

export function useDevValues() {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
}

function el(name: string) {
  return document.querySelector(`[data-dev="${name}"]`) as HTMLElement | null;
}

function applyToDOM(v: DevValues) {
  const header = el("header");
  if (header) header.style.transform = `translateX(${v.headerTx}px)`;

  const subtitle = el("subtitle");
  if (subtitle) subtitle.style.lineHeight = `${v.subtitleLh}`;

  const download = el("download");
  if (download) {
    download.style.marginTop = `${v.downloadAbove}px`;
    download.style.marginBottom = `${v.downloadBelow}px`;
  }

  const featuresUl = el("features-ul");
  if (featuresUl) featuresUl.style.lineHeight = `${v.featuresLh}`;

  const features = el("features");
  if (features) {
    features.style.paddingTop = `${v.featuresPt}px`;
    features.style.paddingBottom = `${v.featuresPb}px`;
  }

  const communityUl = el("community-ul");
  if (communityUl) {
    communityUl.style.display = "flex";
    communityUl.style.flexDirection = "column";
    communityUl.style.gap = `${v.communityGap}px`;
  }

  const faqTopSpacer = el("faq-top-spacer");
  if (faqTopSpacer) faqTopSpacer.style.height = `${v.faqPt}px`;

  const docsContent = el("docs-content");
  if (docsContent) docsContent.style.paddingTop = `${v.docsPt}px`;
}

export function DevPanel() {
  const [visible, setVisible] = useState(false);
  const [pos, setPos] = useState({ x: 0, y: 0 });
  const [dragging, setDragging] = useState(false);
  const [copied, setCopied] = useState(false);
  const vals = useDevValues();
  const dragOffset = useRef({ x: 0, y: 0 });

  useEffect(() => {
    setPos({ x: window.innerWidth - 340, y: window.innerHeight - 320 });
  }, []);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.metaKey && e.key === ".") {
        e.preventDefault();
        setVisible((v) => !v);
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  const update = useCallback((patch: Partial<DevValues>) => {
    setStore(patch);
    applyToDOM({ ...snapshot, ...patch });
  }, []);

  const onPointerDown = useCallback((e: React.PointerEvent) => {
    if ((e.target as HTMLElement).closest("input, button, label")) return;
    setDragging(true);
    dragOffset.current = { x: e.clientX - pos.x, y: e.clientY - pos.y };
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
  }, [pos]);

  const onPointerMove = useCallback((e: React.PointerEvent) => {
    if (!dragging) return;
    setPos({ x: e.clientX - dragOffset.current.x, y: e.clientY - dragOffset.current.y });
  }, [dragging]);

  const onPointerUp = useCallback(() => setDragging(false), []);

  if (process.env.NODE_ENV !== "development" || !visible) return null;

  return (
    <div
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      style={{ left: pos.x, top: pos.y, cursor: dragging ? "grabbing" : "grab" }}
      className="fixed z-[9999] bg-[#222] text-white text-xs rounded-xl p-4 space-y-3 font-mono shadow-lg select-none"
    >
      <div className="flex items-center justify-between gap-4">
        <span className="text-white/50">Dev Controls</span>
        <span className="text-white/20">⌘.</span>
      </div>

      <Section label="Header">
        <Row label="tx" value={vals.headerTx} onChange={(v) => update({ headerTx: v })} min={-50} max={50} step={1} unit="px" />
      </Section>

      <Section label="Cursor">
        <div className="flex items-center gap-3">
          <Row label="top" value={vals.cursorTop} onChange={(v) => update({ cursorTop: v })} min={-5} max={5} step={0.5} unit="px" />
          <label className="flex items-center gap-2 text-white/70 cursor-pointer">
            <input type="checkbox" checked={vals.cursorBlink} onChange={(e) => update({ cursorBlink: e.target.checked })} />
            blink
          </label>
        </div>
      </Section>

      <Section label="Subtitle">
        <Row label="line-h" value={vals.subtitleLh} onChange={(v) => update({ subtitleLh: v })} min={1} max={2.5} step={0.025} unit="" w={16} />
      </Section>

      <Section label="Download buttons">
        <Row label="above" value={vals.downloadAbove} onChange={(v) => update({ downloadAbove: v })} />
        <Row label="below" value={vals.downloadBelow} onChange={(v) => update({ downloadBelow: v })} />
      </Section>

      <Section label="Features">
        <Row label="line-h" value={vals.featuresLh} onChange={(v) => update({ featuresLh: v })} min={1} max={2.5} step={0.025} unit="" w={16} />
        <Row label="pt" value={vals.featuresPt} onChange={(v) => update({ featuresPt: v })} />
        <Row label="pb" value={vals.featuresPb} onChange={(v) => update({ featuresPb: v })} />
      </Section>

      <Section label="Community">
        <Row label="gap" value={vals.communityGap} onChange={(v) => update({ communityGap: v })} />
      </Section>

      <Section label="FAQ">
        <Row label="pt" value={vals.faqPt} onChange={(v) => update({ faqPt: v })} />
      </Section>

      <Section label="Docs">
        <Row label="pt" value={vals.docsPt} onChange={(v) => update({ docsPt: v })} />
      </Section>

      <button
        onClick={() => {
          const text = [
            `header-tx: ${vals.headerTx}px`,
            `cursor-top: ${vals.cursorTop}px`,
            `cursor-blink: ${vals.cursorBlink}`,
            `subtitle-lh: ${vals.subtitleLh}`,
            `download-above: ${vals.downloadAbove}px`,
            `download-below: ${vals.downloadBelow}px`,
            `features-lh: ${vals.featuresLh}`,
            `features-pt: ${vals.featuresPt}px`,
            `features-pb: ${vals.featuresPb}px`,
            `community-gap: ${vals.communityGap}px`,
            `faq-pt: ${vals.faqPt}px`,
            `docs-pt: ${vals.docsPt}px`,
          ].join(", ");
          navigator.clipboard.writeText(text);
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        }}
        className="w-full py-1.5 rounded-lg bg-white/10 hover:bg-white/20 text-white/70 cursor-pointer transition-colors"
      >
        {copied ? "Copied!" : "Copy values"}
      </button>
    </div>
  );
}

function Section({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-2">
      <div className="text-white/40 text-[10px] uppercase tracking-wider">{label}</div>
      {children}
    </div>
  );
}

function Row({ label, value, onChange, min = 0, max = 128, step = 1, unit = "px", w = 10 }: {
  label: string; value: number; onChange: (v: number) => void;
  min?: number; max?: number; step?: number; unit?: string; w?: number;
}) {
  return (
    <div className="flex items-center gap-2">
      <span className="w-12 text-white/70">{label}</span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(parseFloat(e.target.value))}
        className="w-28 accent-blue-500 cursor-pointer"
      />
      <span className="text-right tabular-nums" style={{ width: `${w * 4}px` }}>
        {Number.isInteger(step) ? value : value.toFixed(step < 0.1 ? 2 : 1)}{unit}
      </span>
    </div>
  );
}

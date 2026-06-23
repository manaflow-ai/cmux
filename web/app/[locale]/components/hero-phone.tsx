"use client";

import Image from "next/image";
import { useRef, useState } from "react";
import { Link } from "../../../i18n/navigation";
import phoneImage from "../assets/landing-iphone.png";

// Default placement over the bottom-right of the Mac hero (percent offsets).
const DEFAULT_POS = { right: 15, bottom: -6 };
const STORAGE_KEY = "cmuxHeroPhonePos";

// Add `?drag` to the URL to reposition the phone by dragging. The chosen
// offsets show in a small readout and persist to localStorage; tell us the
// numbers and we bake them as the new default. Off otherwise (the phone is a
// plain link to the iOS docs).
function readInitial(): { right: number; bottom: number } {
  if (typeof window === "undefined") return DEFAULT_POS;
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (raw) return { ...DEFAULT_POS, ...JSON.parse(raw) };
  } catch {
    /* ignore */
  }
  return DEFAULT_POS;
}

export function HeroPhone() {
  const [dragMode] = useState(
    () =>
      typeof window !== "undefined" &&
      new URLSearchParams(window.location.search).has("drag"),
  );
  const [pos, setPos] = useState(readInitial);
  const posRef = useRef(pos);
  const drag = useRef<{
    x: number;
    y: number;
    right: number;
    bottom: number;
    w: number;
    h: number;
  } | null>(null);

  function onPointerDown(e: React.PointerEvent<HTMLDivElement>) {
    const parent = e.currentTarget.offsetParent as HTMLElement | null;
    if (!parent) return;
    const rect = parent.getBoundingClientRect();
    drag.current = {
      x: e.clientX,
      y: e.clientY,
      right: pos.right,
      bottom: pos.bottom,
      w: rect.width,
      h: rect.height,
    };
    e.currentTarget.setPointerCapture(e.pointerId);
  }

  function onPointerMove(e: React.PointerEvent<HTMLDivElement>) {
    const d = drag.current;
    if (!d) return;
    const right = d.right - ((e.clientX - d.x) / d.w) * 100;
    const bottom = d.bottom - ((e.clientY - d.y) / d.h) * 100;
    const next = {
      right: Math.round(right * 10) / 10,
      bottom: Math.round(bottom * 10) / 10,
    };
    posRef.current = next;
    setPos(next);
  }

  function onPointerUp() {
    if (!drag.current) return;
    drag.current = null;
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(posRef.current));
    } catch {
      /* ignore */
    }
  }

  const style: React.CSSProperties = {
    right: `${pos.right}%`,
    bottom: `${pos.bottom}%`,
    ...(dragMode ? { animation: "none" } : null),
  };

  const img = (
    <Image
      src={phoneImage}
      alt="cmux iOS app mirroring a live agent terminal"
      sizes="(max-width: 640px) 34vw, (max-width: 1024px) 26vw, 360px"
      className="w-full h-auto select-none"
      draggable={false}
    />
  );

  return (
    <div
      className="hero-phone pointer-events-none absolute z-10 w-[34%] sm:w-[28%] md:w-[26%] lg:w-[25%] max-w-[360px] drop-shadow-[0_28px_60px_rgba(0,0,0,0.5)]"
      style={style}
    >
      {dragMode ? (
        <div
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          className="pointer-events-auto touch-none cursor-grab active:cursor-grabbing relative"
        >
          {img}
          <div className="absolute -top-7 left-0 whitespace-nowrap rounded bg-black/85 px-2 py-0.5 font-mono text-[11px] text-white">
            right: {pos.right}% · bottom: {pos.bottom}%
          </div>
        </div>
      ) : (
        <Link
          href="/docs/ios"
          aria-label="cmux on iOS"
          className="pointer-events-auto block transition-transform duration-300 ease-out hover:-translate-y-1 hover:scale-[1.02]"
        >
          {img}
        </Link>
      )}
      <style>{`
        .hero-phone {
          animation: heroPhoneIn 1150ms cubic-bezier(.22,1.18,.36,1) 350ms both;
          transform-origin: 70% 100%;
          will-change: transform, opacity, filter;
        }
        @keyframes heroPhoneIn {
          0%   { opacity: 0; transform: translateY(64px) scale(.9) rotate(2.5deg); filter: blur(8px); }
          55%  { opacity: 1; filter: blur(0); }
          100% { opacity: 1; transform: translateY(0) scale(1) rotate(0deg); filter: blur(0); }
        }
        @media (prefers-reduced-motion: reduce) {
          .hero-phone { animation: none; }
        }
      `}</style>
    </div>
  );
}

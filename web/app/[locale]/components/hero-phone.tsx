"use client";

import Image from "next/image";
import { useRef, useState } from "react";
import phoneImage from "../assets/landing-iphone.png";

// TEMP positioning mode: the phone is draggable so we can find the spot.
// Drag it, read the right/bottom % from the badge, and we bake those in
// (then restore the link to /docs/ios and drop the drag handle).
const DEFAULT_POS = { right: 15, bottom: -6 };
const STORAGE_KEY = "cmuxHeroPhonePos";

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
    // offsetParent of this absolutely-positioned div is the hero container.
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

  return (
    <div
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      style={{ right: `${pos.right}%`, bottom: `${pos.bottom}%` }}
      className="hero-phone absolute z-10 w-[34%] sm:w-[28%] md:w-[26%] lg:w-[25%] max-w-[360px] cursor-grab touch-none select-none drop-shadow-[0_28px_60px_rgba(0,0,0,0.5)] active:cursor-grabbing"
    >
      <Image
        src={phoneImage}
        alt="cmux iOS app mirroring a live agent terminal"
        sizes="(max-width: 640px) 34vw, (max-width: 1024px) 26vw, 360px"
        className="pointer-events-none h-auto w-full select-none"
        draggable={false}
      />
      <div className="absolute -top-7 left-0 whitespace-nowrap rounded bg-black/85 px-2 py-0.5 font-mono text-[11px] text-white">
        right: {pos.right}% · bottom: {pos.bottom}%
      </div>
      <style>{`
        .hero-phone {
          animation: heroPhoneIn 1150ms cubic-bezier(.22,1.18,.36,1) 350ms both;
          transform-origin: 70% 100%;
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

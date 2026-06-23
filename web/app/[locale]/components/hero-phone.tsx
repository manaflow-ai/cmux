"use client";

import Image from "next/image";
import { useRef, useState } from "react";
import { Link } from "../../../i18n/navigation";
import phoneImage from "../assets/landing-iphone.png";

// Baked placement over the bottom-right of the Mac hero (percent offsets).
// To retune, open the page with ?drag and drag the phone: the badge shows the
// live right/bottom %, which persist to localStorage. Send us the numbers and
// we update DEFAULT_POS here.
const DEFAULT_POS = { right: -1.2, bottom: -4.3 };
const STORAGE_KEY = "cmuxHeroPhonePos";

const sizeClasses =
  "w-[22%] sm:w-[24%] md:w-[25%] lg:w-[25%] max-w-[360px]";

function readStored(): { right: number; bottom: number } {
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
  const [pos, setPos] = useState(() => (dragMode ? readStored() : DEFAULT_POS));
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
      sizes="(max-width: 640px) 22vw, (max-width: 1024px) 25vw, 360px"
      className="pointer-events-none h-auto w-full select-none"
      draggable={false}
    />
  );

  // Drag mode: reposition the phone and read the live offsets.
  if (dragMode) {
    return (
      <div
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        style={style}
        className={`hero-phone absolute z-10 cursor-grab touch-none select-none drop-shadow-[0_28px_60px_rgba(0,0,0,0.5)] active:cursor-grabbing ${sizeClasses}`}
      >
        {img}
        <div className="absolute -top-7 left-0 whitespace-nowrap rounded bg-black/85 px-2 py-0.5 font-mono text-[11px] text-white">
          right: {pos.right}% · bottom: {pos.bottom}%
        </div>
      </div>
    );
  }

  // Default: static, links to the iOS landing page (no hover scale).
  // No own fade: HeroScreenshot fades the Mac + phone together, in sync.
  return (
    <div
      style={style}
      className={`pointer-events-none absolute z-10 drop-shadow-[0_28px_60px_rgba(0,0,0,0.5)] ${sizeClasses}`}
    >
      <Link href="/ios" aria-label="cmux iOS" className="pointer-events-auto block">
        {img}
      </Link>
    </div>
  );
}

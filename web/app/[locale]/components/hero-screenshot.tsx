"use client";

import Image from "next/image";
import { useState } from "react";
import landingImage from "../assets/landing-image.png";
import { HeroPhone } from "./hero-phone";

// Mac screenshot + overlapping iPhone. Both fade in together, in sync, when
// the Mac image finishes loading (single opacity transition on the container).
export function HeroScreenshot() {
  const [loaded, setLoaded] = useState(false);

  return (
    <div
      className={`relative transition-opacity duration-700 ${loaded ? "opacity-100" : "opacity-0"}`}
    >
      <Image
        src={landingImage}
        alt="cmux terminal app screenshot"
        priority
        onLoad={() => setLoaded(true)}
        className="w-full rounded-xl shadow-[0_30px_80px_-20px_rgba(0,0,0,0.65)]"
      />
      <HeroPhone />
    </div>
  );
}

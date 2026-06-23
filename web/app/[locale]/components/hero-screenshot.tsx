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
      {/* drop-shadow (not box-shadow): box-shadow traces the rectangular
          element box and would square off the corners, showing through the
          image's transparent rounded corners. drop-shadow follows the alpha
          channel, so the shadow hugs the real window corners. */}
      <Image
        src={landingImage}
        alt="cmux terminal app screenshot"
        priority
        quality={85}
        // The screenshot caps at 90rem (1440px) wide and is full-width below
        // that, so tell the browser not to fetch oversized variants on large
        // displays (keeps image transformations and bytes down).
        sizes="(min-width: 1440px) 1440px, 100vw"
        onLoad={() => setLoaded(true)}
        className="w-full [filter:drop-shadow(0_24px_44px_rgba(0,0,0,0.55))]"
      />
      <HeroPhone />
    </div>
  );
}

import Image from "next/image";
import phoneImage from "../assets/landing-iphone.png";

// Framed iPhone overlapping the bottom-right of the Mac hero screenshot.
// Subtle motion: a one-time fade/slide-in on load, then a slow continuous float.
// Both are pure CSS (no JS) and disabled under prefers-reduced-motion.
export function HeroPhone() {
  return (
    <div className="hero-phone pointer-events-none absolute z-10 right-[1%] -bottom-[6%] w-[30%] sm:w-[25%] md:w-[22%] lg:w-[20%] max-w-[260px]">
      <div className="hero-phone-float drop-shadow-[0_28px_60px_rgba(0,0,0,0.5)]">
        <Image
          src={phoneImage}
          alt="cmux iOS app mirroring a live agent terminal"
          sizes="(max-width: 640px) 30vw, (max-width: 1024px) 22vw, 260px"
          className="w-full h-auto select-none"
        />
      </div>
      <style>{`
        .hero-phone { animation: heroPhoneIn 1000ms cubic-bezier(.2,.7,.2,1) 450ms both; }
        .hero-phone-float { animation: heroPhoneFloat 6.5s ease-in-out infinite; will-change: transform; }
        @keyframes heroPhoneIn {
          from { opacity: 0; transform: translateY(36px) scale(.95); }
          to   { opacity: 1; transform: translateY(0) scale(1); }
        }
        @keyframes heroPhoneFloat {
          0%, 100% { transform: translateY(0); }
          50%      { transform: translateY(-10px); }
        }
        @media (prefers-reduced-motion: reduce) {
          .hero-phone, .hero-phone-float { animation: none; }
        }
      `}</style>
    </div>
  );
}

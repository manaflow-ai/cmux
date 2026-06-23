import Image from "next/image";
import { Link } from "../../../i18n/navigation";
import phoneImage from "../assets/landing-iphone.png";

// Framed iPhone overlapping the bottom-right of the Mac hero screenshot.
// Subtle motion: a single fade/slide-in on load. No continuous animation.
// Pure CSS (no JS) and disabled under prefers-reduced-motion. Links to the iOS docs.
export function HeroPhone() {
  return (
    <div className="hero-phone pointer-events-none absolute z-10 right-[7%] -bottom-[6%] w-[34%] sm:w-[28%] md:w-[26%] lg:w-[25%] max-w-[360px] drop-shadow-[0_28px_60px_rgba(0,0,0,0.5)]">
      <Link
        href="/docs/ios"
        aria-label="cmux on iOS"
        className="pointer-events-auto block transition-transform duration-300 ease-out hover:-translate-y-1 hover:scale-[1.02]"
      >
        <Image
          src={phoneImage}
          alt="cmux iOS app mirroring a live agent terminal"
          sizes="(max-width: 640px) 34vw, (max-width: 1024px) 26vw, 360px"
          className="w-full h-auto select-none"
        />
      </Link>
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

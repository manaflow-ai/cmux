import Image from "next/image";
import Link from "next/link";
import { NavLinks } from "./nav-links";

export function SiteHeader({ section, hideLogo }: { section?: string; hideLogo?: boolean }) {
  return (
    <header className="sticky top-0 z-30 w-full bg-background/80 backdrop-blur-sm">
      <div className="w-full max-w-5xl mx-auto flex items-center justify-between px-6 h-12">
        <div className="flex items-center gap-3">
          {!hideLogo && (
            <>
              <Link href="/" className="flex items-center gap-2.5">
                <Image
                  src="/icon.png"
                  alt="cmux"
                  width={24}
                  height={24}
                  className="rounded-md"
                  unoptimized
                />
                <span className="text-sm font-semibold tracking-tight">
                  cmux
                </span>
              </Link>
              {section && (
                <>
                  <span className="text-border text-[13px]">/</span>
                  <span className="text-[13px] text-muted">{section}</span>
                </>
              )}
            </>
          )}
        </div>
        <nav className="flex items-center gap-4 text-sm text-muted">
          <NavLinks />
        </nav>
      </div>
    </header>
  );
}

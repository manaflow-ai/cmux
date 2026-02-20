"use client";

import Link from "next/link";
import posthog from "posthog-js";

export function NavLinks() {
  return (
    <>
      <Link
        href="/docs/getting-started"
        className="hover:text-foreground transition-colors"
      >
        Docs
      </Link>
      <Link
        href="/blog"
        className="hover:text-foreground transition-colors"
      >
        Blog
      </Link>
      <Link
        href="/docs/changelog"
        className="hover:text-foreground transition-colors"
      >
        Changelog
      </Link>
      <Link
        href="/community"
        className="hover:text-foreground transition-colors"
      >
        Community
      </Link>
      <a
        href="https://github.com/manaflow-ai/cmux"
        target="_blank"
        rel="noopener noreferrer"
        onClick={() => posthog.capture("cmuxterm_github_clicked", { location: "navbar" })}
        className="hover:text-foreground transition-colors"
      >
        GitHub
      </a>
    </>
  );
}

export function SiteFooter() {
  return (
    <footer className="py-8 flex justify-center">
      <div className="flex flex-wrap justify-center items-center gap-4 text-sm text-muted px-6">
        <a
          href="https://github.com/manaflow-ai/cmux"
          target="_blank"
          rel="noopener noreferrer"
          onClick={() => posthog.capture("cmuxterm_github_clicked", { location: "footer" })}
          className="hover:text-foreground transition-colors"
        >
          GitHub
        </a>
        <a href="https://twitter.com/manaflowai" target="_blank" rel="noopener noreferrer" className="hover:text-foreground transition-colors">X / Twitter</a>
        <a href="https://www.linkedin.com/company/manaflow-ai/" target="_blank" rel="noopener noreferrer" className="hover:text-foreground transition-colors">LinkedIn</a>
        <a href="https://discord.com/invite/QRxkhZgY" target="_blank" rel="noopener noreferrer" className="hover:text-foreground transition-colors">Discord</a>
        <Link href="/privacy-policy" className="hover:text-foreground transition-colors">Privacy</Link>
        <Link href="/terms-of-service" className="hover:text-foreground transition-colors">Terms</Link>
        <Link href="/eula" className="hover:text-foreground transition-colors">EULA</Link>
        <a href="mailto:founders@manaflow.com" className="hover:text-foreground transition-colors">Contact</a>
      </div>
    </footer>
  );
}

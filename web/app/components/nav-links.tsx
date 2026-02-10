import Link from "next/link";
import { DownloadButton } from "./download-button";

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
        className="hover:text-foreground transition-colors"
      >
        GitHub
      </a>
      <DownloadButton size="sm" />
    </>
  );
}

export function SiteFooter() {
  return (
    <footer className="py-8 flex justify-center">
      <div className="flex items-center gap-4 text-sm text-muted">
        <a href="https://github.com/manaflow-ai/cmux" target="_blank" rel="noopener noreferrer" className="hover:text-foreground transition-colors">GitHub</a>
        <a href="https://twitter.com/manaflowai" target="_blank" rel="noopener noreferrer" className="hover:text-foreground transition-colors">Twitter</a>
        <a href="https://discord.gg/SDbQmzQhRK" target="_blank" rel="noopener noreferrer" className="hover:text-foreground transition-colors">Discord</a>
        <Link href="/privacy-policy" className="hover:text-foreground transition-colors">Privacy</Link>
        <Link href="/terms-of-service" className="hover:text-foreground transition-colors">Terms</Link>
        <Link href="/eula" className="hover:text-foreground transition-colors">EULA</Link>
        <a href="mailto:founders@manaflow.com" className="hover:text-foreground transition-colors">Contact</a>
      </div>
    </footer>
  );
}

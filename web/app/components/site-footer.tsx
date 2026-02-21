import Link from "next/link";

const columns = [
  {
    heading: "Product",
    links: [
      { label: "Blog", href: "/blog" },
      { label: "Community", href: "/community" },
    ],
  },
  {
    heading: "Resources",
    links: [
      { label: "Docs", href: "/docs/getting-started" },
      { label: "Changelog", href: "/docs/changelog" },
    ],
  },
  {
    heading: "Legal",
    links: [
      { label: "Privacy", href: "/privacy-policy" },
      { label: "Terms", href: "/terms-of-service" },
      { label: "EULA", href: "/eula" },
    ],
  },
  {
    heading: "Connect",
    links: [
      { label: "GitHub", href: "https://github.com/manaflow-ai/cmux" },
      { label: "X", href: "https://twitter.com/manaflowai" },
      { label: "Discord", href: "https://discord.gg/xsgFEVrWCZ" },
      { label: "Contact", href: "mailto:founders@manaflow.com" },
    ],
  },
];

function isExternal(href: string) {
  return href.startsWith("http") || href.startsWith("mailto:");
}

export function SiteFooter() {
  const year = new Date().getFullYear();

  return (
    <footer className="border-t border-border mt-16">
      <div className="max-w-2xl mx-auto px-6 py-12">
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-8">
          {columns.map((col) => (
            <div key={col.heading}>
              <h3 className="text-xs font-medium text-muted tracking-tight mb-3">
                {col.heading}
              </h3>
              <ul className="space-y-2">
                {col.links.map((link) => (
                  <li key={link.href}>
                    {isExternal(link.href) ? (
                      <a
                        href={link.href}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-sm text-muted hover:text-foreground transition-colors"
                      >
                        {link.label}
                      </a>
                    ) : (
                      <Link
                        href={link.href}
                        className="text-sm text-muted hover:text-foreground transition-colors"
                      >
                        {link.label}
                      </Link>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
        <p className="text-xs text-muted mt-10">
          &copy; {year} Manaflow
        </p>
      </div>
    </footer>
  );
}

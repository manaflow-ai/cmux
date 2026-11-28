import { useTranslations } from "next-intl";
import type { CSSProperties, ReactNode } from "react";

type DocsHeadingLevel = 1 | 2 | 3;

type DocsHeadingProps = {
  children: ReactNode;
  className?: string;
  id: string;
  level: DocsHeadingLevel;
  style?: CSSProperties;
};

function classNames(...values: Array<string | undefined>) {
  return values.filter(Boolean).join(" ");
}

export function DocsHeading({
  children,
  className,
  id,
  level,
  style,
}: DocsHeadingProps) {
  const t = useTranslations("docs.headingAnchors");
  const sharedProps = {
    className: classNames("docs-heading", className),
    id,
    style,
  };
  const content = (
    <>
      <a
        aria-label={t("link")}
        className="docs-heading-anchor"
        data-pagefind-ignore="all"
        href={`#${id}`}
      >
        <svg
          width="12"
          height="12"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
          <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
        </svg>
      </a>
      {children}
    </>
  );

  if (level === 1) {
    return <h1 {...sharedProps}>{content}</h1>;
  }

  if (level === 2) {
    return <h2 {...sharedProps}>{content}</h2>;
  }

  return <h3 {...sharedProps}>{content}</h3>;
}

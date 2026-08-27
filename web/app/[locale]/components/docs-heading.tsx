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
        #
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

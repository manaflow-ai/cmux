import { codeToHtml } from "shiki";
import { CodeCopyButton } from "./code-copy-button";

const frameClass =
  "not-prose group relative mb-6 mt-4 overflow-hidden rounded-xl border border-border bg-code-bg";

function CodeHeader({ label }: { label: string }) {
  return (
    <div className="flex h-10 items-center justify-between border-b border-border pl-4 pr-1.5">
      <span className="truncate font-mono text-[12px] text-muted">{label}</span>
      <CodeCopyButton />
    </div>
  );
}

export async function CodeBlock({
  children,
  title,
  lang,
  variant = "code",
}: {
  children: string;
  title?: string;
  lang?: string;
  variant?: "code" | "ascii";
}) {
  "use cache";

  const plainLineHeightClass =
    variant === "ascii" ? "leading-[1.15]" : "leading-[22px]";
  const shikiLineHeightClass =
    variant === "ascii" ? "[&_pre]:leading-[1.15]" : "[&_pre]:leading-[22px]";
  // Like Mintlify, only a titled block (a file name) gets a header bar.
  const headerLabel = title;
  // Without a header the copy button floats over the code and appears on hover.
  const floatingCopy = headerLabel ? null : (
    <CodeCopyButton className="absolute right-2.5 top-2.5 bg-code-bg opacity-0 group-hover:opacity-100 focus-visible:opacity-100" />
  );

  if (lang && variant !== "ascii") {
    const html = await codeToHtml(children, {
      lang,
      themes: { light: "github-light", dark: "github-dark" },
      defaultColor: false,
    });

    return (
      <div className={frameClass} data-code-block>
        {headerLabel && <CodeHeader label={headerLabel} />}
        <div
          className={`[&_pre]:m-0 [&_pre]:bg-transparent [&_pre]:px-4 [&_pre]:py-3.5 [&_pre]:overflow-x-auto [&_pre]:text-[13px] ${shikiLineHeightClass} [&_pre]:font-mono [&_code]:bg-transparent [&_code]:p-0 [&_code]:text-[1em]`}
          dangerouslySetInnerHTML={{ __html: html }}
        />
        {floatingCopy}
      </div>
    );
  }

  return (
    <div className={frameClass} data-code-block>
      {headerLabel && <CodeHeader label={headerLabel} />}
      <pre
        className={`m-0 px-4 py-3.5 overflow-x-auto text-[13px] ${plainLineHeightClass} ${
          variant === "ascii" ? "" : "font-mono"
        }`}
        style={
          variant === "ascii"
            ? {
                fontFamily:
                  "Menlo, Monaco, Consolas, 'Courier New', monospace",
              }
            : undefined
        }
      >
        <code style={variant === "ascii" ? { fontFamily: "inherit" } : undefined}>
          {children}
        </code>
      </pre>
      {floatingCopy}
    </div>
  );
}

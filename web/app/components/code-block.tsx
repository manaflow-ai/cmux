import { codeToHtml } from "shiki";

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
  const lineHeightClass =
    variant === "ascii" ? "leading-[1.15]" : "leading-[1.45]";

  if (lang && variant !== "ascii") {
    const html = await codeToHtml(children, {
      lang,
      themes: { light: "github-light", dark: "github-dark" },
      defaultColor: false,
    });

    return (
      <div className="mb-4">
        {title && (
          <div className="text-[11px] font-mono text-muted px-4 py-1.5 bg-code-bg border border-border border-b-0 rounded-t-lg">
            {title}
          </div>
        )}
        <div
          className={`[&_pre]:bg-code-bg [&_pre]:border [&_pre]:border-border [&_pre]:px-4 [&_pre]:py-3 [&_pre]:overflow-x-auto [&_pre]:text-[13px] [&_pre]:${lineHeightClass} [&_pre]:font-mono ${
            title
              ? "[&_pre]:rounded-b-lg [&_pre]:border-t-0"
              : "[&_pre]:rounded-lg"
          } [&_code]:bg-transparent [&_code]:p-0`}
          dangerouslySetInnerHTML={{ __html: html }}
        />
      </div>
    );
  }

  return (
    <div className="mb-4">
      {title && (
        <div className="text-[11px] font-mono text-muted px-4 py-1.5 bg-code-bg border border-border border-b-0 rounded-t-lg">
          {title}
        </div>
      )}
      <pre
        className={`bg-code-bg border border-border px-4 py-3 overflow-x-auto text-[13px] ${lineHeightClass} font-mono ${
          title ? "rounded-b-lg" : "rounded-lg"
        }`}
      >
        <code>{children}</code>
      </pre>
    </div>
  );
}

"use client";

import { ContextMenu } from "@base-ui-components/react/context-menu";
import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { Link } from "../../../i18n/navigation";

export function BrandLogoLink({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) {
  const t = useTranslations("brandLogoMenu");

  return (
    <ContextMenu.Root>
      <ContextMenu.Trigger render={<div className="inline-flex" />}>
        <Link href="/" className={className}>
          {children}
        </Link>
      </ContextMenu.Trigger>
      <ContextMenu.Portal>
        <ContextMenu.Positioner sideOffset={8}>
          <ContextMenu.Popup className="z-50 min-w-56 rounded-lg border border-border bg-background p-1.5 shadow-xl shadow-black/10 outline-none">
            <ContextMenu.Group>
              <ContextMenu.GroupLabel className="px-2.5 py-2 text-xs text-muted">
                {t("label")}
              </ContextMenu.GroupLabel>
              <BrandMenuItem
                href="/brand/app-icon-light.png"
                download="app-icon-light.png"
                label={t("downloadLight")}
              >
                <LightIcon />
              </BrandMenuItem>
              <BrandMenuItem
                href="/brand/app-icon-dark.png"
                download="app-icon-dark.png"
                label={t("downloadDark")}
              >
                <DarkIcon />
              </BrandMenuItem>
            </ContextMenu.Group>
            <ContextMenu.Separator className="my-1 h-px bg-border" />
            <ContextMenu.Item
              render={<Link href="/assets" />}
              className={menuItemClass}
            >
              <GridIcon />
              <span>{t("brandPage")}</span>
            </ContextMenu.Item>
          </ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  );
}

const menuItemClass =
  "flex min-h-9 cursor-default select-none items-center gap-3 rounded-md px-2.5 py-2 text-sm text-foreground outline-none hover:bg-code-bg data-[highlighted]:bg-code-bg";

function BrandMenuItem({
  children,
  download,
  href,
  label,
}: {
  children: ReactNode;
  download: string;
  href: string;
  label: string;
}) {
  return (
    <ContextMenu.Item
      render={<a href={href} download={download} />}
      className={menuItemClass}
    >
      {children}
      <span>{label}</span>
    </ContextMenu.Item>
  );
}

function LightIcon() {
  return (
    <span
      className="flex h-5 w-5 shrink-0 items-center justify-center rounded bg-[#f7f7f7]"
      aria-hidden="true"
    >
      <span className="h-2.5 w-2.5 rounded-sm bg-[#171717]" />
    </span>
  );
}

function DarkIcon() {
  return (
    <span
      className="flex h-5 w-5 shrink-0 items-center justify-center rounded bg-[#171717]"
      aria-hidden="true"
    >
      <span className="h-2.5 w-2.5 rounded-sm bg-[#f7f7f7]" />
    </span>
  );
}

function GridIcon() {
  return (
    <span
      className="grid h-5 w-5 shrink-0 grid-cols-2 gap-0.5 text-muted"
      aria-hidden="true"
    >
      <span className="rounded-sm border border-current" />
      <span className="rounded-sm border border-current" />
      <span className="rounded-sm border border-current" />
      <span className="rounded-sm border border-current" />
    </span>
  );
}

"use client";

import { ContextMenu } from "@base-ui-components/react/context-menu";
import Image from "next/image";
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
        <ContextMenu.Positioner sideOffset={8} className="z-[1000]">
          <ContextMenu.Popup className="z-[1000] min-w-64 rounded-lg border border-border bg-background p-1.5 shadow-xl shadow-black/10 outline-none">
            <ContextMenu.Group>
              <ContextMenu.GroupLabel className="px-2.5 py-2 text-xs text-muted">
                {t("label")}
              </ContextMenu.GroupLabel>
              <BrandMenuItem
                href="/brand/app-icon-light.png"
                download="app-icon-light.png"
                label={t("downloadLight")}
              >
                <MenuIconImage
                  src="/brand/app-icon-light.png"
                  alt=""
                />
              </BrandMenuItem>
              <BrandMenuItem
                href="/brand/app-icon-dark.png"
                download="app-icon-dark.png"
                label={t("downloadDark")}
              >
                <MenuIconImage
                  src="/brand/app-icon-dark.png"
                  alt=""
                />
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
  "flex min-h-10 cursor-default select-none items-center gap-3 rounded-md px-2.5 py-2 text-sm text-foreground outline-none hover:bg-code-bg data-[highlighted]:bg-code-bg";

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

function MenuIconImage({
  alt,
  src,
}: {
  alt: string;
  src: string;
}) {
  return (
    <Image
      src={src}
      alt={alt}
      width={1024}
      height={1024}
      unoptimized
      className="h-8 w-8 shrink-0 object-contain"
      aria-hidden="true"
    />
  );
}

function GridIcon() {
  return (
    <span
      className="flex h-8 w-8 shrink-0 items-center justify-center text-muted"
      aria-hidden="true"
    >
      <span className="grid h-5 w-5 grid-cols-2 gap-0.5">
        <span className="rounded-sm border border-current" />
        <span className="rounded-sm border border-current" />
        <span className="rounded-sm border border-current" />
        <span className="rounded-sm border border-current" />
      </span>
    </span>
  );
}

import { getTranslations } from "next-intl/server";
import { artCollections, localizedArtTitle, type ArtWork } from "./art-manifest";

/** Every work, grouped by its picker collection in picker order. */
export async function ArtGallery({ locale, works }: { locale: string; works: ArtWork[] | null }) {
  const t = await getTranslations({ locale, namespace: "art" });
  if (!works || works.length === 0) {
    return <p className="text-muted text-[15px]">{t("unavailable")}</p>;
  }
  const groups = artCollections
    .map((collection) => ({ collection, works: works.filter((work) => work.collection === collection) }))
    .filter((group) => group.works.length > 0);
  return (
    <>
      <nav aria-label={t("collectionsLabel")} className="flex flex-wrap gap-x-4 gap-y-1 mb-8 text-[14px]">
        {groups.map(({ collection, works: groupWorks }) => (
          <a key={collection} href={`#${collection}`} className="underline decoration-link-underline underline-offset-2">
            {t(`collections.${collection}`)} <span className="text-muted">({groupWorks.length})</span>
          </a>
        ))}
      </nav>
      {groups.map(({ collection, works: groupWorks }) => (
        <section key={collection} id={collection} className="mb-12 scroll-mt-20">
          <h2 className="text-lg font-semibold tracking-tight mb-4">{t(`collections.${collection}`)}</h2>
          <ul className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
            {groupWorks.map((work) => (
              <ArtCard key={work.id} work={work} title={localizedArtTitle(work, locale)} sourceLabel={t("source")} />
            ))}
          </ul>
        </section>
      ))}
    </>
  );
}

function ArtCard({ work, title, sourceLabel }: { work: ArtWork; title: string; sourceLabel: string }) {
  return (
    <li className="min-w-0">
      <a href={work.image} className="block overflow-hidden rounded-md border border-border bg-code-bg">
        {/* eslint-disable-next-line @next/next/no-img-element -- files.cmux.com thumbnails are already 480x300 AVIF */}
        <img
          src={work.thumbnail}
          alt={`${title} — ${work.artist}`}
          width={480}
          height={300}
          loading="lazy"
          decoding="async"
          className="block w-full h-auto aspect-[8/5] object-cover"
        />
      </a>
      <p className="mt-2 text-[14px] font-medium leading-snug truncate" title={title}>{title}</p>
      <p className="text-[13px] text-muted truncate">
        {work.artist}
        {work.year ? ` · ${work.year}` : ""}
      </p>
      <a
        href={work.source}
        className="text-[12px] text-muted underline decoration-link-underline underline-offset-2"
        aria-label={`${sourceLabel}: ${title}`}
      >
        {sourceLabel}
      </a>
    </li>
  );
}

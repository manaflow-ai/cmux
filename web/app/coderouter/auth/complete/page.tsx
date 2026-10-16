import type { Metadata } from "next";
import Image from "next/image";
import { getTranslations } from "next-intl/server";
import styles from "./page.module.css";

export const instant = false;

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations("coderouterAuth");
  return {
    title: `${t("title")} · coderouter`,
    robots: { index: false, follow: false },
    referrer: "no-referrer",
  };
}

// This page acknowledges the local callback only. The CLI completes token
// exchange and account upload; no credentials or query parameters are needed.
export default async function CoderouterAuthCompletePage() {
  const t = await getTranslations("coderouterAuth");
  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <div className={styles.brand}>
          <Image src="/logo.png" alt="" width={24} height={24} />
          <span className={styles.brandName}>cmux</span>
          <span className={styles.divider} aria-hidden="true">/</span>
          <span className={styles.product}>coderouter</span>
        </div>
      </header>
      <main className={styles.main}>
        <section className={styles.confirmation} aria-labelledby="confirmation-title">
          <h1 id="confirmation-title" className={styles.title}>
            <span className={styles.status} aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="m5 12 4 4 10-10" />
              </svg>
            </span>
            <span>{t("title")}</span>
          </h1>
          <p className={styles.description}>{t("description")}</p>
        </section>
      </main>
    </div>
  );
}

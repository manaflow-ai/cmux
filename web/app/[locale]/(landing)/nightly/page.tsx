import { CMUX_NIGHTLY_DMG_URL } from "@/app/lib/nightly-downloads";
import {
  NightlyDownloadPage,
  nightlyDownloadMetadata,
} from "../nightly-download-page";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  return nightlyDownloadMetadata(locale, "nightly", "/nightly");
}

export default function NightlyPage() {
  return (
    <NightlyDownloadPage
      namespace="nightly"
      iconSrc="/logo-nightly.png"
      iconAlt="cmux NIGHTLY icon"
      downloadUrl={CMUX_NIGHTLY_DMG_URL}
    />
  );
}

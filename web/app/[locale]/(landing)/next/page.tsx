import { CMUX_NEXT_NIGHTLY_DMG_URL } from "@/app/lib/nightly-downloads";
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
  return nightlyDownloadMetadata(locale, "next", "/next");
}

export default function NextNightlyPage() {
  return (
    <NightlyDownloadPage
      namespace="next"
      iconSrc="/logo-next-nightly.png"
      iconAlt="cmux NEXT NIGHTLY icon"
      downloadUrl={CMUX_NEXT_NIGHTLY_DMG_URL}
    />
  );
}

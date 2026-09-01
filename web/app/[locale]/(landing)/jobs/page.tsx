import type { Metadata } from "next";
import { JobsPageContent, jobsMetadata } from "./job-role-page";

const path = "/jobs";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  return jobsMetadata({
    params,
    path,
  });
}

export default function JobsPage() {
  return <JobsPageContent />;
}

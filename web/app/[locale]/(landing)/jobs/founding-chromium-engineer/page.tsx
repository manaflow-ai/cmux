import type { Metadata } from "next";
import { JobsPageContent, jobRoleMetadata } from "../job-role-page";

const path = "/jobs/founding-chromium-engineer";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  return jobRoleMetadata({
    params,
    path,
    namespace: "jobs.foundingChromiumEngineer",
  });
}

export default function FoundingChromiumEngineerPage() {
  return <JobsPageContent />;
}

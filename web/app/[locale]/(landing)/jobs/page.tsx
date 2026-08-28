import type { Metadata } from "next";
import { JobRolePage, jobRoleMetadata } from "./job-role-page";

const path = "/jobs";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  return jobRoleMetadata({
    params,
    path,
    namespace: "jobs",
  });
}

export default function JobsPage() {
  return (
    <JobRolePage
      namespace="jobs"
      roleLinkHref="/jobs/founding-designer"
      showRoleDirectory
    />
  );
}

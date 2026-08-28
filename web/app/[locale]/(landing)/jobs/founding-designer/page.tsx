import type { Metadata } from "next";
import { JobRolePage, jobRoleMetadata } from "../job-role-page";

const path = "/jobs/founding-designer";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  return jobRoleMetadata({
    params,
    path,
    namespace: "jobs.foundingDesigner",
  });
}

export default function FoundingDesignerPage() {
  return (
    <JobRolePage
      namespace="jobs.foundingDesigner"
      backHref="/jobs"
      roleLinkHref="/jobs"
    />
  );
}

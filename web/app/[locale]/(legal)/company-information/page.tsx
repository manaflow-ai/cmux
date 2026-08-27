import type { Metadata } from "next";
import { JsonLd } from "../../components/json-ld";
import { legalMetadata } from "../legal-metadata";

const legalName = "Manaflow, Inc.";
const contactEmail = "founders@manaflow.com";
const streetAddress = "501 2nd Street, Suite 350";
const locality = "San Francisco";
const region = "CA";
const postalCode = "94107";

export const metadata: Metadata = {
  ...legalMetadata(
    "/company-information",
    "Company information — cmux",
    "Legal entity, address, contact, and domain information for cmux and Manaflow",
  ),
  robots: {
    index: false,
    follow: false,
  },
};

const organizationJsonLd = {
  "@context": "https://schema.org",
  "@type": "Organization",
  name: "Manaflow",
  legalName,
  url: "https://manaflow.com",
  email: contactEmail,
  address: {
    "@type": "PostalAddress",
    streetAddress,
    addressLocality: locality,
    addressRegion: region,
    postalCode,
    addressCountry: "US",
  },
  contactPoint: {
    "@type": "ContactPoint",
    contactType: "general inquiries",
    email: contactEmail,
  },
  sameAs: ["https://cmux.com", "https://manaflow.com"],
};

export default function CompanyInformationPage() {
  return (
    <>
      <JsonLd data={organizationJsonLd} />
      <h1>Company information</h1>
      <p>
        This page provides the official legal entity and domain information for
        cmux.
      </p>

      <dl className="my-8 grid max-w-3xl gap-0 overflow-hidden rounded-lg border border-border">
        <CompanyDetail term="Legal entity">{legalName}</CompanyDetail>
        <CompanyDetail term="Business address">
          <address className="not-italic">
            {streetAddress}
            <br />
            {locality}, {region} {postalCode}
            <br />
            United States
          </address>
        </CompanyDetail>
        <CompanyDetail term="Contact">
          <a href={`mailto:${contactEmail}`}>{contactEmail}</a>
        </CompanyDetail>
        <CompanyDetail term="Company domain">
          <a href="https://manaflow.com">manaflow.com</a>
        </CompanyDetail>
        <CompanyDetail term="Product domain">
          <a href="https://cmux.com">cmux.com</a>
        </CompanyDetail>
      </dl>

      <h2>Domain ownership and operation</h2>
      <p>
        {legalName} owns and operates <a href="https://manaflow.com">manaflow.com</a>{" "}
        and <a href="https://cmux.com">cmux.com</a>. cmux is developed and
        operated by {legalName}.
      </p>
      <p>Last updated: July 30, 2026</p>
    </>
  );
}

function CompanyDetail({
  term,
  children,
}: {
  readonly term: string;
  readonly children: React.ReactNode;
}) {
  return (
    <div className="grid gap-1 border-b border-border px-5 py-4 last:border-b-0 sm:grid-cols-[11rem_1fr] sm:gap-6">
      <dt className="font-medium">{term}</dt>
      <dd>{children}</dd>
    </div>
  );
}

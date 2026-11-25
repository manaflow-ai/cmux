// Settings > Cloud > Cloud Credentials (keyless cloud credentials, https://github.com/manaflow-ai/cmux/issues/48427):
// each provider's setup steps for the team's cmux OIDC issuer, as text the person copies. Pure: the card draws them.
// Commands, policies and paths are code, never translated; each step's sentence is a catalog key.
import type { CloudCredentialsInfo } from "./ops";

export type CloudCredentialsProvider = "aws" | "gcp" | "azure" | "vault" | "generic";
export const CLOUD_CREDENTIALS_PROVIDERS: ReadonlyArray<CloudCredentialsProvider> = [
  "aws",
  "gcp",
  "azure",
  "vault",
  "generic",
];

/** Where cmux keeps the machine's token (cmux-host oidc_token.rs) and the marker naming its audience. */
export const TOKEN_FILE = "/run/cmux-oidc/token";
export const AUDIENCE_FILE = "~/.config/cmux/oidc/audience";

/** The audience each provider expects by default (the machine's marker names it). */
export const PROVIDER_AUDIENCE: Record<CloudCredentialsProvider, string> = {
  aws: "sts.amazonaws.com",
  gcp: "//iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/cmux/providers/cmux",
  azure: "api://AzureADTokenExchange",
  vault: "vault",
  generic: "YOUR_AUDIENCE",
};

export type SetupStep = { readonly where: "cloud" | "machine"; readonly code: string };

const audienceStep = (audience: string) => `mkdir -p ~/.config/cmux/oidc && echo '${audience}' > ${AUDIENCE_FILE}`;

/** The issuer without its scheme, as AWS names an OIDC provider and its condition keys. */
const hostPath = (issuer: string) => issuer.replace(/^https?:\/\//, "");

/** One provider's steps for this team: first in the customer's cloud, then on the Cloud machine. */
export function setupSteps(provider: CloudCredentialsProvider, info: CloudCredentialsInfo): ReadonlyArray<SetupStep> {
  const { issuer, team } = info;
  const audience = PROVIDER_AUDIENCE[provider];
  const subjects = `team:${team}:machine:*`;
  switch (provider) {
    case "aws": {
      const host = hostPath(issuer);
      const trust = {
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Principal: { Federated: `arn:aws:iam::ACCOUNT_ID:oidc-provider/${host}` },
            Action: "sts:AssumeRoleWithWebIdentity",
            Condition: {
              StringEquals: { [`${host}:aud`]: audience },
              StringLike: { [`${host}:sub`]: subjects },
            },
          },
        ],
      };
      return [
        {
          where: "cloud",
          code: `aws iam create-open-id-connect-provider --url ${issuer} --client-id-list ${audience}\n\ncat > cmux-trust.json <<'EOF'\n${JSON.stringify(trust, null, 2)}\nEOF\naws iam create-role --role-name cmux-machines --assume-role-policy-document file://cmux-trust.json`,
        },
        {
          where: "machine",
          code: `${audienceStep(audience)}\nexport AWS_ROLE_ARN=arn:aws:iam::ACCOUNT_ID:role/cmux-machines\nexport AWS_WEB_IDENTITY_TOKEN_FILE=${TOKEN_FILE}`,
        },
      ];
    }
    case "gcp":
      return [
        {
          where: "cloud",
          code: `gcloud iam workload-identity-pools create cmux --location=global\ngcloud iam workload-identity-pools providers create-oidc cmux --location=global \\\n  --workload-identity-pool=cmux --issuer-uri=${issuer} \\\n  --attribute-mapping=google.subject=assertion.sub,attribute.team=assertion.team,attribute.machine=assertion.machine \\\n  --attribute-condition="assertion.team=='${team}'"\ngcloud iam service-accounts add-iam-policy-binding SERVICE_ACCOUNT_EMAIL \\\n  --role=roles/iam.workloadIdentityUser \\\n  --member="principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/cmux/attribute.team/${team}"`,
        },
        {
          where: "machine",
          code: `${audienceStep(audience)}\ngcloud iam workload-identity-pools create-cred-config \\\n  projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/cmux/providers/cmux \\\n  --service-account=SERVICE_ACCOUNT_EMAIL --credential-source-file=${TOKEN_FILE} \\\n  --output-file=$HOME/.config/gcloud/cmux-credentials.json\nexport GOOGLE_APPLICATION_CREDENTIALS=$HOME/.config/gcloud/cmux-credentials.json`,
        },
      ];
    case "azure":
      return [
        {
          where: "cloud",
          code: `az identity federated-credential create --name cmux-MACHINE_ID \\\n  --identity-name IDENTITY_NAME --resource-group RESOURCE_GROUP \\\n  --issuer ${issuer} --subject team:${team}:machine:MACHINE_ID --audiences ${audience}`,
        },
        {
          where: "machine",
          code: `${audienceStep(audience)}\nexport AZURE_CLIENT_ID=CLIENT_ID AZURE_TENANT_ID=TENANT_ID\nexport AZURE_FEDERATED_TOKEN_FILE=${TOKEN_FILE}`,
        },
      ];
    case "vault":
      return [
        {
          where: "cloud",
          code: `vault auth enable jwt\nvault write auth/jwt/config oidc_discovery_url=${issuer} bound_issuer=${issuer}\nvault write auth/jwt/role/cmux - <<'EOF'\n${JSON.stringify(
            {
              role_type: "jwt",
              bound_audiences: [audience],
              user_claim: "sub",
              bound_claims: { team },
              token_policies: ["POLICY"],
            },
            null,
            2,
          )}\nEOF`,
        },
        {
          where: "machine",
          code: `${audienceStep(audience)}\nvault write auth/jwt/login role=cmux jwt=@${TOKEN_FILE}`,
        },
      ];
    case "generic":
      return [
        {
          where: "cloud",
          code: `issuer:          ${issuer}\ndiscovery:       ${info.discovery_url}\njwks_uri:        ${info.jwks_url}\nalgorithm:       ${info.signing_alg}\nsubject:         ${info.subject_format}\nclaims:          iss sub aud exp iat nbf jti team machine user\nttl_seconds:     ${info.default_ttl_seconds} (60-${info.max_ttl_seconds})`,
        },
        { where: "machine", code: `${audienceStep(audience)}\ncat ${TOKEN_FILE}` },
      ];
  }
}

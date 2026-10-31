//! Public names and the edge: `domain` (verified domains, their
//! verifications and certificates) and `tls` (TLS routing rules and
//! forward-auth checks).
//!
//! Header values of TLS rules and forward-auth checks are write-only: they are
//! sent from flags or files and never printed; responses name the headers
//! only. A rule or check read with `--json` can be edited and sent back with
//! `--file`: the response-only fields are ignored.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use cmux_vm_client::raw::{Client, types};
use serde_json::{Map, Value, json};

use crate::access::checked_id;
use crate::error::CliError;
use crate::output::Printer;
use crate::prompt::Prompt;
use crate::{Destroy, call, confirm, fetch_body, request_body};

#[derive(Subcommand, Debug)]
pub(crate) enum DomainCommand {
    /// List the team's verified domains and the managed hostname suffix
    List,
    /// Show a verified domain and the DNS records it needs
    Get(DomainArg),
    /// Release a verified domain (asks to type the domain id, or needs --yes)
    Delete(DomainDeleteArgs),
    /// Start verifying a domain; prints the TXT record to add to its DNS
    VerifyCreate(VerifyCreateArgs),
    /// List the team's domain verifications
    Verifications(VerificationListArgs),
    /// Show one domain verification and its TXT record
    Verification(VerificationArg),
    /// Check the TXT record and verify the domain
    Verify(VerificationArg),
    /// Withdraw a domain verification (asks to type its id, or needs --yes)
    VerificationDelete(VerificationDeleteArgs),
    /// List the certificates of the team's verified domains
    Certs,
    /// Request an ongoing wildcard certificate for a verified domain
    Wildcard(DomainArg),
}

#[derive(Args, Debug)]
pub(crate) struct DomainArg {
    /// Domain id (dom_...)
    domain_id: String,
}

#[derive(Args, Debug)]
pub(crate) struct DomainDeleteArgs {
    /// Domain id (dom_...)
    domain_id: String,
    /// Release without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

#[derive(Args, Debug)]
pub(crate) struct VerifyCreateArgs {
    /// The domain to prove control of, such as example.com
    domain: String,
}

#[derive(Args, Debug)]
pub(crate) struct VerificationListArgs {
    /// Only verifications in this state
    #[arg(long, value_parser = ["pending", "verified"])]
    state: Option<String>,
}

#[derive(Args, Debug)]
pub(crate) struct VerificationArg {
    /// Domain verification id (dvr_...)
    verification_id: String,
}

#[derive(Args, Debug)]
pub(crate) struct VerificationDeleteArgs {
    /// Domain verification id (dvr_...)
    verification_id: String,
    /// Withdraw without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

#[derive(Subcommand, Debug)]
pub(crate) enum TlsCommand {
    /// List the team's TLS rules
    List(TlsListArgs),
    /// Show a TLS rule (header values are never shown)
    Get(TlsRuleArg),
    /// Create a TLS rule: --host H --vm VM --port N routes a public name to a VM, or --file for any rule
    Create(TlsRuleArgs),
    /// Replace a TLS rule with a whole new one. Header values are write-only, so
    /// a rule that sets headers needs them again (--header, --headers-file or a
    /// `headers` field in the file) or --clear-headers to drop them
    Update(TlsUpdateArgs),
    /// Delete a TLS rule (asks to type the rule id, or needs --yes)
    Delete(TlsDeleteArgs),
    /// Forward-auth checks the edge runs before a protected request
    #[command(subcommand)]
    ForwardAuth(ForwardAuthCommand),
}

#[derive(Args, Debug)]
pub(crate) struct TlsListArgs {
    /// Only rules naming this VM (vm_...)
    #[arg(long, value_name = "VM_ID")]
    vm: Option<String>,
}

#[derive(Args, Debug)]
pub(crate) struct TlsRuleArg {
    /// TLS rule id (tlsr_...)
    rule_id: String,
}

#[derive(Args, Debug)]
pub(crate) struct TlsDeleteArgs {
    /// TLS rule id (tlsr_...)
    rule_id: String,
    /// Delete without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

#[derive(Args, Debug)]
pub(crate) struct TlsRuleArgs {
    /// JSON file with the whole rule (domain, protocol, source, destination,
    /// forwardAuthId, match, headers, description); `tls get --json` output works
    #[arg(long, value_name = "FILE", conflicts_with_all = ["host", "vm", "port"])]
    file: Option<PathBuf>,
    /// Public hostname: a managed name or a name under a verified domain
    #[arg(long, value_name = "HOST", required_unless_present = "file", requires_all = ["vm", "port"])]
    host: Option<String>,
    /// Destination VM (vm_...)
    #[arg(long, value_name = "VM_ID")]
    vm: Option<String>,
    /// Destination port on the VM
    #[arg(long, value_parser = clap::value_parser!(u16).range(1..))]
    port: Option<u16>,
    /// Protocol at the edge [default: http]
    #[arg(long, value_parser = ["http", "tcp", "postgres", "minecraft", "imap", "imaps"])]
    protocol: Option<String>,
    /// Require this forward-auth check (fwa_...)
    #[arg(long, value_name = "ID")]
    forward_auth: Option<String>,
    /// Free text description
    #[arg(long)]
    description: Option<String>,
    /// Header to add, NAME=VALUE; repeat for several (prefer --headers-file for secrets)
    #[arg(long = "header", value_name = "NAME=VALUE")]
    headers: Vec<String>,
    /// JSON object of header names to values, kept off the command line
    #[arg(long, value_name = "FILE")]
    headers_file: Option<PathBuf>,
}

#[derive(Args, Debug)]
pub(crate) struct TlsUpdateArgs {
    /// TLS rule id (tlsr_...)
    rule_id: String,
    #[command(flatten)]
    rule: TlsRuleArgs,
    /// Remove the headers the rule sets (the update names none)
    #[arg(long, conflicts_with_all = ["headers", "headers_file"])]
    clear_headers: bool,
}

#[derive(Subcommand, Debug)]
pub(crate) enum ForwardAuthCommand {
    /// List the team's forward-auth checks
    List,
    /// Show a forward-auth check (header values are never shown)
    Get(ForwardAuthArg),
    /// Create a forward-auth check from a JSON file (url, headers, authResponseHeaders, protectedCookies, timeoutMs)
    Create(ForwardAuthFileArgs),
    /// Replace a forward-auth check from a JSON file. A check that sends headers
    /// needs them again in the file's `headers`, or --clear-headers to drop them
    Update(ForwardAuthUpdateArgs),
    /// Delete a forward-auth check (asks to type its id, or needs --yes)
    Delete(ForwardAuthDeleteArgs),
}

#[derive(Args, Debug)]
pub(crate) struct ForwardAuthArg {
    /// Forward-auth id (fwa_...)
    forward_auth_id: String,
}

#[derive(Args, Debug)]
pub(crate) struct ForwardAuthFileArgs {
    /// JSON file with the check; `tls forward-auth get --json` output works
    #[arg(long, value_name = "FILE")]
    file: PathBuf,
}

#[derive(Args, Debug)]
pub(crate) struct ForwardAuthUpdateArgs {
    /// Forward-auth id (fwa_...)
    forward_auth_id: String,
    /// JSON file with the whole check
    #[arg(long, value_name = "FILE")]
    file: PathBuf,
    /// Remove the headers the check sends (the file names none)
    #[arg(long)]
    clear_headers: bool,
}

#[derive(Args, Debug)]
pub(crate) struct ForwardAuthDeleteArgs {
    /// Forward-auth id (fwa_...)
    forward_auth_id: String,
    /// Delete without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

pub(crate) async fn domain(
    client: &Client,
    command: DomainCommand,
    prompt: &mut dyn Prompt,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match command {
        DomainCommand::List => {
            let body = fetch_body(client.domains_list_domains(None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let list = decode(&body)?;
            let items = list["items"].as_array().cloned().unwrap_or_default();
            if items.is_empty() {
                out.line("no verified domains")?;
            } else {
                out.line(&format!("{:<31} {:<40} VERIFIED", "ID", "DOMAIN"))?;
                for domain in items {
                    out.line(&format!(
                        "{:<31} {:<40} {}",
                        text(&domain, "/id"),
                        text(&domain, "/domain").escape_debug(),
                        text(&domain, "/verifiedAt")
                    ))?;
                }
            }
            if let Some(suffix) = list["managedSuffix"].as_str() {
                out.line(&format!(
                    "managed hostnames: <name>{}",
                    suffix.escape_debug()
                ))?;
            }
            Ok(())
        }
        DomainCommand::Get(DomainArg { domain_id }) => {
            let id = checked_id(&domain_id, "dom_", "domain id")?;
            out.domain(&fetch_body(client.domains_get_domain(id, None)).await?)
        }
        DomainCommand::Delete(args) => {
            let id = checked_id(&args.domain_id, "dom_", "domain id")?;
            if !args.yes {
                confirm(prompt, Destroy::DeleteDomain, id)?;
            }
            call(client.domains_delete_domain(id, None)).await?;
            out.deleted(id)
        }
        DomainCommand::VerifyCreate(args) => {
            let body: types::CreateDomainVerificationRequest =
                request_body(json!({ "domain": args.domain }))?;
            let body = fetch_body(client.domains_create_domain_verification(None, &body)).await?;
            out.verification(&body, true)
        }
        DomainCommand::Verifications(args) => {
            let state = crate::parse_opt::<types::DomainsListDomainVerificationsState>(
                "--state", args.state,
            )?;
            let body = fetch_body(client.domains_list_domain_verifications(state, None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let items = decode(&body)?["items"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            if items.is_empty() {
                return out.line("no domain verifications");
            }
            out.line(&format!("{:<31} {:<9} DOMAIN", "ID", "STATE"))?;
            for item in items {
                out.line(&format!(
                    "{:<31} {:<9} {}",
                    text(&item, "/id"),
                    text(&item, "/state"),
                    text(&item, "/domain").escape_debug()
                ))?;
            }
            Ok(())
        }
        DomainCommand::Verification(VerificationArg { verification_id }) => {
            let id = checked_id(&verification_id, "dvr_", "domain verification id")?;
            let body = fetch_body(client.domains_get_domain_verification(id, None)).await?;
            out.verification(&body, false)
        }
        DomainCommand::Verify(VerificationArg { verification_id }) => {
            let id = checked_id(&verification_id, "dvr_", "domain verification id")?;
            out.domain(&fetch_body(client.domains_verify_domain(id, None)).await?)
        }
        DomainCommand::VerificationDelete(args) => {
            let id = checked_id(&args.verification_id, "dvr_", "domain verification id")?;
            if !args.yes {
                confirm(prompt, Destroy::DeleteVerification, id)?;
            }
            call(client.domains_delete_domain_verification(id, None)).await?;
            out.deleted(id)
        }
        DomainCommand::Certs => {
            let body = fetch_body(client.domains_list_certificates(None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let items = decode(&body)?["items"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            if items.is_empty() {
                return out.line("no certificates");
            }
            out.line(&format!(
                "{:<40} {:<9} {:<7} NOT_AFTER",
                "DOMAIN", "WILDCARD", "ACTIVE"
            ))?;
            for cert in items {
                out.certificate_row(&cert)?;
            }
            Ok(())
        }
        DomainCommand::Wildcard(DomainArg { domain_id }) => {
            let id = checked_id(&domain_id, "dom_", "domain id")?;
            let body = fetch_body(client.domains_request_wildcard_certificate(id, None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            out.certificate_row(&decode(&body)?)
        }
    }
}

pub(crate) async fn tls(
    client: &Client,
    command: TlsCommand,
    prompt: &mut dyn Prompt,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match command {
        TlsCommand::List(args) => {
            let vm = crate::parse_opt::<types::TlsRulesListTlsRulesVmId>("--vm", args.vm)?;
            let body = fetch_body(client.tls_rules_list_tls_rules(vm.as_ref(), None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let items = decode(&body)?["items"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            if items.is_empty() {
                return out.line("no TLS rules");
            }
            out.line(&format!(
                "{:<32} {:<8} {:<10} {:<40} DESTINATION",
                "ID", "DIR", "PROTOCOL", "DOMAIN"
            ))?;
            for rule in items {
                out.line(&format!(
                    "{:<32} {:<8} {:<10} {:<40} {}",
                    text(&rule, "/id"),
                    text(&rule, "/direction"),
                    text(&rule, "/protocol"),
                    text(&rule, "/domain").escape_debug(),
                    destination(&rule["destination"]).escape_debug()
                ))?;
            }
            Ok(())
        }
        TlsCommand::Get(TlsRuleArg { rule_id }) => {
            let id = checked_id(&rule_id, "tlsr_", "TLS rule id")?;
            out.tls_rule(&fetch_body(client.tls_rules_get_tls_rule(id, None)).await?)
        }
        TlsCommand::Create(args) => {
            let body: types::TlsRuleRequest = request_body(tls_rule_body(&args)?)?;
            out.tls_rule(&fetch_body(client.tls_rules_create_tls_rule(None, &body)).await?)
        }
        TlsCommand::Update(args) => {
            let id = checked_id(&args.rule_id, "tlsr_", "TLS rule id")?;
            let body = tls_rule_body(&args.rule)?;
            // The API clears the headers of a rule replaced without them, and
            // their values cannot be read back: refuse to drop them silently.
            if needs_current_headers(&body, args.clear_headers, "TLS rule")? {
                let current = fetch_body(client.tls_rules_get_tls_rule(id, None)).await?;
                keep_or_refuse_headers(&decode(&current)?, id, "--header, --headers-file")?;
            }
            let body: types::TlsRuleRequest = request_body(body)?;
            out.tls_rule(&fetch_body(client.tls_rules_update_tls_rule(id, None, &body)).await?)
        }
        TlsCommand::Delete(args) => {
            let id = checked_id(&args.rule_id, "tlsr_", "TLS rule id")?;
            if !args.yes {
                confirm(prompt, Destroy::DeleteTlsRule, id)?;
            }
            call(client.tls_rules_delete_tls_rule(id, None)).await?;
            out.deleted(id)
        }
        TlsCommand::ForwardAuth(command) => forward_auth(client, command, prompt, out).await,
    }
}

async fn forward_auth(
    client: &Client,
    command: ForwardAuthCommand,
    prompt: &mut dyn Prompt,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match command {
        ForwardAuthCommand::List => {
            let body = fetch_body(client.tls_forward_auth_list_tls_forward_auths(None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let items = decode(&body)?["items"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            if items.is_empty() {
                return out.line("no forward-auth checks");
            }
            out.line(&format!("{:<31} URL", "ID"))?;
            for check in items {
                out.line(&format!(
                    "{:<31} {}",
                    text(&check, "/id"),
                    text(&check, "/url").escape_debug()
                ))?;
            }
            Ok(())
        }
        ForwardAuthCommand::Get(ForwardAuthArg { forward_auth_id }) => {
            let id = checked_id(&forward_auth_id, "fwa_", "forward-auth id")?;
            out.forward_auth(
                &fetch_body(client.tls_forward_auth_get_tls_forward_auth(id, None)).await?,
            )
        }
        ForwardAuthCommand::Create(args) => {
            let body: types::TlsForwardAuthRequest = request_body(forward_auth_body(&args.file)?)?;
            out.forward_auth(
                &fetch_body(client.tls_forward_auth_create_tls_forward_auth(None, &body)).await?,
            )
        }
        ForwardAuthCommand::Update(args) => {
            let id = checked_id(&args.forward_auth_id, "fwa_", "forward-auth id")?;
            let body = forward_auth_body(&args.file)?;
            if needs_current_headers(&body, args.clear_headers, "forward-auth check")? {
                let current =
                    fetch_body(client.tls_forward_auth_get_tls_forward_auth(id, None)).await?;
                keep_or_refuse_headers(&decode(&current)?, id, "the file's `headers`")?;
            }
            let body: types::TlsForwardAuthRequest = request_body(body)?;
            out.forward_auth(
                &fetch_body(client.tls_forward_auth_update_tls_forward_auth(id, None, &body))
                    .await?,
            )
        }
        ForwardAuthCommand::Delete(args) => {
            let id = checked_id(&args.forward_auth_id, "fwa_", "forward-auth id")?;
            if !args.yes {
                confirm(prompt, Destroy::DeleteForwardAuth, id)?;
            }
            call(client.tls_forward_auth_delete_tls_forward_auth(id, None)).await?;
            out.deleted(id)
        }
    }
}

/// Whether an update body leaves the headers out, so the current ones must be
/// checked before the API clears them. `--clear-headers` with headers in the
/// body is a contradiction.
pub(crate) fn needs_current_headers(
    body: &Value,
    clear_headers: bool,
    what: &str,
) -> Result<bool, CliError> {
    let names_headers = body
        .get("headers")
        .is_some_and(|headers| !headers.is_null());
    if clear_headers && names_headers {
        return Err(CliError::usage(format!(
            "--clear-headers removes the {what}'s headers; the update also sets headers"
        )));
    }
    Ok(!clear_headers && !names_headers)
}

/// Refuses an update that names no headers when the current rule or check
/// sets some (`headerNames`): the API would clear them.
pub(crate) fn keep_or_refuse_headers(current: &Value, id: &str, how: &str) -> Result<(), CliError> {
    let names: Vec<&str> = current["headerNames"]
        .as_array()
        .map(|names| names.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    if names.is_empty() {
        return Ok(());
    }
    Err(CliError::usage(format!(
        "{id} sets the headers {}; their values are write-only and this update names none, so it would clear them. Send them again ({how}), or pass --clear-headers to remove them",
        names.join(", ").escape_debug()
    )))
}

/// Fields a rule or check has in a response but not in a request.
const RESPONSE_ONLY: &[&str] = &["id", "direction", "headerNames", "createdAt", "updatedAt"];

/// The request body of `tls create|update`: the file (response-only fields
/// dropped), or an ingress rule from flags. Header flags and `--headers-file`
/// override the file's headers.
pub(crate) fn tls_rule_body(args: &TlsRuleArgs) -> Result<Value, CliError> {
    let mut rule = match &args.file {
        Some(file) => object_file(file, "rule file")?,
        None => {
            let (Some(host), Some(vm), Some(port)) = (&args.host, &args.vm, args.port) else {
                return Err(CliError::usage(
                    "tls needs --file, or --host, --vm and --port",
                ));
            };
            let vm = crate::files::vm_id(vm)?;
            let mut rule = Map::new();
            rule.insert("domain".into(), json!(host));
            rule.insert("source".into(), json!({ "public": true }));
            rule.insert(
                "destination".into(),
                json!({ "vmId": vm.as_str(), "port": port }),
            );
            rule
        }
    };
    for (key, value) in [
        ("protocol", &args.protocol),
        ("forwardAuthId", &args.forward_auth),
        ("description", &args.description),
    ] {
        if let Some(value) = value {
            rule.insert(key.into(), json!(value));
        }
    }
    if let Some(headers) =
        crate::network::proxy_headers(&args.headers, args.headers_file.as_deref())?
    {
        rule.insert("headers".into(), headers);
    }
    Ok(Value::Object(rule))
}

pub(crate) fn forward_auth_body(file: &std::path::Path) -> Result<Value, CliError> {
    Ok(Value::Object(object_file(file, "forward-auth file")?))
}

/// A JSON object file without the response-only fields.
fn object_file(file: &std::path::Path, what: &str) -> Result<Map<String, Value>, CliError> {
    match crate::network::read_json_file(file, what)? {
        Value::Object(mut fields) => {
            for key in RESPONSE_ONLY {
                fields.remove(*key);
            }
            Ok(fields)
        }
        _ => Err(CliError::usage(format!("the {what} must be a JSON object"))),
    }
}

/// A rule's destination in a few words: `vm_…:8080`, a host, or `public`.
fn destination(value: &Value) -> String {
    match (
        value["vmId"].as_str(),
        value["host"].as_str(),
        &value["port"],
    ) {
        (Some(vm), _, Value::Number(port)) => format!("{vm}:{port}"),
        (Some(vm), _, _) => vm.to_owned(),
        (None, Some(host), Value::Number(port)) => format!("{host}:{port}"),
        (None, Some(host), _) => host.to_owned(),
        _ if value["public"] == true => "public".to_owned(),
        _ => "-".to_owned(),
    }
}

fn text(value: &Value, pointer: &str) -> String {
    match value.pointer(pointer) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => "-".to_owned(),
        Some(other) => other.to_string(),
    }
}

fn decode(body: &[u8]) -> Result<Value, CliError> {
    serde_json::from_slice(body).map_err(|e| {
        CliError::unexpected(format!(
            "the cmux VM API sent a response this CLI cannot read: {e}"
        ))
    })
}

impl Printer<'_> {
    fn domain(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.is_json() {
            return self.raw_json(body);
        }
        let domain = decode(body)?;
        self.line(&format!("{:<10}{}", "id", text(&domain, "/id")))?;
        self.line(&format!(
            "{:<10}{}",
            "domain",
            text(&domain, "/domain").escape_debug()
        ))?;
        self.line(&format!(
            "{:<10}{}",
            "verified",
            text(&domain, "/verifiedAt")
        ))?;
        for (label, pointer) in [
            ("routing", "/dns/routing"),
            ("wildcard", "/dns/wildcardCertificate"),
        ] {
            if let Some(record) = domain.pointer(pointer).filter(|r| r.is_object()) {
                self.line(&format!("{label:<10}{}", dns_record(record)))?;
            }
        }
        Ok(())
    }

    fn verification(&mut self, body: &[u8], created: bool) -> Result<(), CliError> {
        if self.is_json() {
            return self.raw_json(body);
        }
        let verification = decode(body)?;
        self.line(&format!("{:<10}{}", "id", text(&verification, "/id")))?;
        self.line(&format!(
            "{:<10}{}",
            "domain",
            text(&verification, "/domain").escape_debug()
        ))?;
        self.line(&format!("{:<10}{}", "state", text(&verification, "/state")))?;
        self.line(&format!(
            "{:<10}{}",
            "record",
            dns_record(&verification["record"])
        ))?;
        if created || verification["state"] == "pending" {
            self.line(&format!(
                "Add the record to the domain's DNS, then run `cmux-vm domain verify {}`.",
                text(&verification, "/id")
            ))?;
        }
        Ok(())
    }

    fn certificate_row(&mut self, cert: &Value) -> Result<(), CliError> {
        self.line(&format!(
            "{:<40} {:<9} {:<7} {}",
            text(cert, "/domain").escape_debug(),
            text(cert, "/wildcard"),
            text(cert, "/active"),
            text(cert, "/notAfter")
        ))
    }

    fn tls_rule(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.is_json() {
            return self.raw_json(body);
        }
        let rule = decode(body)?;
        let headers = rule["headerNames"]
            .as_array()
            .map(|names| {
                names
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .unwrap_or_default();
        let source = if rule.pointer("/source/public") == Some(&Value::Bool(true)) {
            "public".to_owned()
        } else {
            text(&rule, "/source/vmId")
        };
        for (label, value) in [
            ("id", text(&rule, "/id")),
            ("domain", text(&rule, "/domain")),
            ("protocol", text(&rule, "/protocol")),
            ("direction", text(&rule, "/direction")),
            ("source", source),
            ("dest", destination(&rule["destination"])),
            ("auth", text(&rule, "/forwardAuthId")),
            ("headers", headers),
            ("note", text(&rule, "/description")),
            ("updated", text(&rule, "/updatedAt")),
        ] {
            self.line(&format!("{label:<10}{}", value.escape_debug()))?;
        }
        Ok(())
    }

    fn forward_auth(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.is_json() {
            return self.raw_json(body);
        }
        let check = decode(body)?;
        let list = |pointer: &str| {
            check
                .pointer(pointer)
                .and_then(Value::as_array)
                .map(|names| {
                    names
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default()
        };
        for (label, value) in [
            ("id", text(&check, "/id")),
            ("url", text(&check, "/url")),
            ("headers", list("/headerNames")),
            ("passes", list("/authResponseHeaders")),
            ("cookies", list("/protectedCookies")),
            ("timeout", format!("{} ms", text(&check, "/timeoutMs"))),
        ] {
            self.line(&format!("{label:<10}{}", value.escape_debug()))?;
        }
        Ok(())
    }
}

fn dns_record(record: &Value) -> String {
    format!(
        "{} {} {}",
        text(record, "/type"),
        text(record, "/name"),
        text(record, "/value")
    )
    .escape_debug()
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flags(host: &str) -> TlsRuleArgs {
        TlsRuleArgs {
            file: None,
            host: Some(host.to_owned()),
            vm: Some("vm_0123456789abcdefghjkmnpqrs".to_owned()),
            port: Some(8080),
            protocol: None,
            forward_auth: None,
            description: None,
            headers: vec![],
            headers_file: None,
        }
    }

    #[test]
    fn the_common_rule_routes_a_public_host_to_a_vm_port() {
        assert_eq!(
            tls_rule_body(&flags("app.example.com")).unwrap(),
            json!({
                "domain": "app.example.com",
                "source": {"public": true},
                "destination": {"vmId": "vm_0123456789abcdefghjkmnpqrs", "port": 8080},
            })
        );
        let mut args = flags("db.example.com");
        args.protocol = Some("postgres".into());
        args.headers = vec!["x-a=1".into()];
        let body = tls_rule_body(&args).unwrap();
        assert_eq!(body["protocol"], "postgres");
        assert_eq!(body["headers"], json!({"x-a": "1"}));
        let mut args = flags("x");
        args.vm = Some("nope".into());
        assert!(tls_rule_body(&args).is_err());
    }

    #[test]
    fn a_rule_file_drops_response_only_fields() {
        let dir = std::env::temp_dir().join(format!("cmux-vm-edge-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rule.json");
        std::fs::write(
            &file,
            serde_json::to_vec(
                &json!({"id": "tlsr_x", "direction": "ingress", "headerNames": [],
                "createdAt": "t", "updatedAt": "t", "domain": "a.example.com",
                "source": {"public": true}, "destination": {"vmId": "vm_1", "port": 80}}),
            )
            .unwrap(),
        )
        .unwrap();
        let mut args = flags("unused");
        args.file = Some(file);
        args.host = None;
        let body = tls_rule_body(&args).unwrap();
        assert_eq!(
            body,
            json!({"domain": "a.example.com", "source": {"public": true}, "destination": {"vmId": "vm_1", "port": 80}})
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn destinations_read_as_vm_port_host_or_public() {
        assert_eq!(destination(&json!({"vmId": "vm_1", "port": 80})), "vm_1:80");
        assert_eq!(
            destination(&json!({"host": "api.example.com"})),
            "api.example.com"
        );
        assert_eq!(destination(&json!({"public": true})), "public");
        assert_eq!(destination(&json!({})), "-");
    }

    #[test]
    fn an_update_without_headers_is_refused_while_the_rule_sets_some() {
        let current = json!({"headerNames": ["x-secret", "x-other"]});
        // No headers in the update: the current rule is checked.
        assert!(needs_current_headers(&json!({"domain": "a"}), false, "TLS rule").unwrap());
        let refused = keep_or_refuse_headers(&current, "tlsr_x", "--header").unwrap_err();
        assert_eq!(refused.exit_code(), crate::exit::USAGE);
        assert!(keep_or_refuse_headers(&json!({"headerNames": []}), "tlsr_x", "--header").is_ok());
        // Headers sent again, or an explicit clear: no check needed.
        assert!(
            !needs_current_headers(&json!({"headers": {"x-secret": "v"}}), false, "TLS rule")
                .unwrap()
        );
        assert!(!needs_current_headers(&json!({}), true, "TLS rule").unwrap());
        assert!(needs_current_headers(&json!({"headers": {"a": "b"}}), true, "TLS rule").is_err());
    }
}

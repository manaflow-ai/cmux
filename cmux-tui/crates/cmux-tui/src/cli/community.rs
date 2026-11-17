//! `cmux theme install|update|remove|installed` and `cmux snippet ...`:
//! community themes and snippets from git repositories, the two no-code
//! tiers beside extensions (plugins).
//!
//! A reference is `[https://]HOST/OWNER/REPO[/PATH][@REF]`, as for
//! `cmux apps install`. No ref follows releases: the newest version tag
//! (`1.2.0` or `v1.2.0`, a release's tag), else the default branch. The ref
//! resolves to a 40-hex commit (`git ls-remote`), that one commit is
//! fetched shallow into a scratch repository (any https host; no checkout,
//! no hooks, no filters), and only the files the tier installs are read out
//! of it (`git cat-file`). The format and the apply are cmux_customize's
//! `community` module: one library entry, one generation, undone with
//! `remove`, `cmux customize library off` or `cmux customize rollback`.
//!
//! Before anything is written, one line says what it is and that no code
//! runs; a terminal asks, anything else needs `--yes`.

use cmux_process::{Command, Stdio};
use std::io::{IsTerminal, Write as _};
use std::path::{Path, PathBuf};

use cmux_customize::Customize;
use cmux_customize::community::{self, Receipt, SNIPPET_FILES, Tier};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::{GlobalArgs, OutputMode};

pub(super) const THEME_USAGE: &str = "\
  cmux theme install HOST/OWNER/REPO[/PATH][@REF] [--yes]   a community theme from a git repository
  cmux theme update [ID|REF] [--yes]                 follow new releases (every installed theme with none)
  cmux theme remove ID|REF                            take it out; what was under it comes back
  cmux theme installed                                community themes and where they came from";

const SNIPPET_USAGE: &str = "\
cmux snippet: small no-code customizations (a few settings, a stylesheet) from git repositories.
  cmux snippet install HOST/OWNER/REPO[/PATH][@REF] [--yes]
  cmux snippet update [ID|REF] [--yes]
  cmux snippet remove ID|REF
  cmux snippet installed
A snippet repository has cmux-snippet.json at its root; a theme repository cmux-theme.json.";

/// The verbs `cmux theme` hands to this module.
pub(super) const THEME_VERBS: &[&str] = &["install", "update", "remove", "uninstall", "installed"];

/// The registry repository's lists (contract A): listed = reviewed.
const REGISTRY_REPO: &str = "https://github.com/manaflow-ai/cmux-extensions.git";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Request {
    Install { reference: String, yes: bool },
    Update { which: Option<String>, yes: bool },
    Remove { which: String },
    Installed,
    Help,
}

/// `cmux [globals] theme|snippet VERB ...` for this module's verbs.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, words) = super::parse_globals(args).ok()?;
    let (scope, rest) = words.split_first()?;
    let tier = match scope.as_str() {
        "theme" if rest.first().is_some_and(|verb| THEME_VERBS.contains(&verb.as_str())) => {
            Tier::Theme
        }
        "snippet" | "snippets" => Tier::Snippet,
        _ => return None,
    };
    let rest: Vec<String> = rest
        .iter()
        .filter(|word| {
            let json = *word == "--json";
            if json {
                global.output = OutputMode::Json;
            }
            !json
        })
        .cloned()
        .collect();
    let usage = if tier == Tier::Theme { THEME_USAGE } else { SNIPPET_USAGE };
    let request = match parse(&rest) {
        Ok(request) => request,
        Err(what) => {
            return Some(super::scope_usage_failure(global.output, tier.name(), &what, usage));
        }
    };
    if request == Request::Help {
        println!("{usage}");
        return Some(0);
    }
    let customize = match Customize::from_env() {
        Ok(customize) => customize,
        Err(error) => return Some(fail(&global, error.code(), error.to_string(), None)),
    };
    let git = Git::network();
    Some(run(&global, &customize, &git, tier, request, &mut Consent::Terminal))
}

pub(super) fn parse(words: &[String]) -> Result<Request, String> {
    let Some((verb, args)) = words.split_first() else { return Ok(Request::Help) };
    let yes = args.iter().any(|w| w == "--yes" || w == "-y");
    let positional: Vec<&String> = args.iter().filter(|w| !w.starts_with('-')).collect();
    if let Some(flag) =
        args.iter().find(|w| w.starts_with('-') && !matches!(w.as_str(), "--yes" | "-y"))
    {
        return Err(format!("{verb} does not take {flag}"));
    }
    let one = |what: &str| -> Result<String, String> {
        match positional.as_slice() {
            [one] => Ok((*one).clone()),
            [] => Err(format!("{verb} takes {what}")),
            _ => Err(format!("{verb} takes one {what}")),
        }
    };
    Ok(match verb.as_str() {
        "install" | "add" => {
            Request::Install { reference: one("a repository (HOST/OWNER/REPO[@REF])")?, yes }
        }
        "update" | "upgrade" => match positional.as_slice() {
            [] => Request::Update { which: None, yes },
            _ => Request::Update { which: Some(one("ID or reference")?), yes },
        },
        "remove" | "uninstall" => Request::Remove { which: one("ID or reference")? },
        "installed" | "list" | "ls" if positional.is_empty() => Request::Installed,
        "-h" | "--help" | "help" => Request::Help,
        other => return Err(format!("unknown verb {other:?}")),
    })
}

/// How a terminal says yes to the card.
pub(super) enum Consent {
    /// Ask on the terminal when stdin is one; refuse otherwise.
    Terminal,
    /// Tests: answer this.
    #[cfg(test)]
    Answer(bool),
}

impl Consent {
    fn ask(&mut self, card: &str, global: &GlobalArgs) -> bool {
        match self {
            Consent::Terminal => {
                if global.output != OutputMode::Human || !std::io::stdin().is_terminal() {
                    return false;
                }
                eprint!("{card}\nContinue? [y/N] ");
                let _ = std::io::stderr().flush();
                let mut line = String::new();
                std::io::stdin().read_line(&mut line).is_ok()
                    && matches!(line.trim().to_ascii_lowercase().as_str(), "y" | "yes")
            }
            #[cfg(test)]
            Consent::Answer(answer) => *answer,
        }
    }
}

fn fail(global: &GlobalArgs, code: &str, message: String, details: Option<Value>) -> i32 {
    let mut error = json!({ "code": code, "message": message });
    if let (Some(details), Some(map)) = (details, error.as_object_mut()) {
        map.insert("details".to_owned(), details);
    }
    super::wire::print_local_error(&error, global.output, 1)
}

fn ok(global: &GlobalArgs, value: &Value, human: &str) -> i32 {
    match global.output {
        OutputMode::Json | OutputMode::JsonLines => {
            super::wire::print_local_success(value, global.output)
        }
        OutputMode::Quiet => 0,
        OutputMode::Human => {
            println!("{}", human.trim_end());
            0
        }
    }
}

/// `cmux theme check DIR` on a theme or snippet repository folder: the
/// marker, every theme file, and the art (type, size and count).
pub(super) fn check_dir(global: &GlobalArgs, dir: &Path) -> i32 {
    match community::read_package(dir) {
        Ok(package) => {
            let mut human = format!(
                "{}: {} {} is fine; theme files: {}; {} images",
                dir.display(),
                package.tier.name(),
                package.id,
                package.themes.join(", "),
                package.art.images.len()
            );
            if !package.art.applied.is_empty() {
                human.push_str(&format!("\n  applied: {}", package.art.applied.join(", ")));
            }
            if !package.art.pending.is_empty() {
                human.push_str(&format!(
                    "\n  not applied yet (no cmux setting): {}",
                    package.art.pending.join(", ")
                ));
            }
            let value = json!({
                "ok": true,
                "tier": package.tier.name(),
                "id": package.id,
                "themes": package.themes,
                "images": package.art.images,
                "applied": package.art.applied,
                "pending": package.art.pending,
            });
            ok(global, &value, &human)
        }
        Err(error) => fail(global, "community.invalid", error.to_string(), None),
    }
}

pub(super) fn run(
    global: &GlobalArgs,
    customize: &Customize,
    git: &Git,
    tier: Tier,
    request: Request,
    consent: &mut Consent,
) -> i32 {
    let now = super::customize::now_ms();
    match request {
        Request::Help => 0,
        Request::Installed => match customize.community(Some(tier)) {
            Ok(installed) => {
                let mut human = String::new();
                if installed.is_empty() {
                    human = format!("no community {}s installed\n", tier.name());
                }
                for receipt in &installed {
                    human.push_str(&format!(
                        "{}  {}  {}@{}  (library entry {})\n",
                        receipt.id,
                        receipt.name,
                        receipt.reference,
                        receipt.tag.clone().unwrap_or_else(|| short(&receipt.commit).to_owned()),
                        receipt.entry
                    ));
                }
                ok(global, &json!({ "installed": installed }), &human)
            }
            Err(error) => fail(global, error.code(), error.to_string(), None),
        },
        Request::Remove { which } => match customize.community_remove(tier, &which, "cli", now) {
            Ok((receipt, change)) => {
                let human = format!(
                    "removed {} {} ({}); what was under it is back",
                    tier.name(),
                    receipt.id,
                    receipt.reference
                );
                ok(global, &json!({ "removed": receipt, "change": change }), &human)
            }
            Err(error) => fail(global, error.code(), error.to_string(), None),
        },
        Request::Install { reference, yes } => {
            let reference = match RepoRef::parse(&reference) {
                Ok(reference) => reference,
                Err(why) => return fail(global, "community.reference", why, None),
            };
            match install(global, customize, git, tier, &reference, None, yes, consent, now) {
                Ok((value, human)) => ok(global, &value, &human),
                Err(failure) => failure.print(global),
            }
        }
        Request::Update { which, yes } => {
            let targets = match &which {
                Some(which) => customize.community_find(tier, which).map(|r| vec![r]),
                None => customize.community(Some(tier)),
            };
            let targets = match targets {
                Ok(targets) => targets,
                Err(error) => return fail(global, error.code(), error.to_string(), None),
            };
            let mut results = Vec::new();
            let mut human = String::new();
            if targets.is_empty() {
                human = format!("no community {}s installed\n", tier.name());
            }
            for receipt in targets {
                let reference = match RepoRef::parse(&receipt.reference) {
                    Ok(reference) => RepoRef { git_ref: receipt.git_ref.clone(), ..reference },
                    Err(why) => return fail(global, "community.reference", why, None),
                };
                match install(
                    global,
                    customize,
                    git,
                    tier,
                    &reference,
                    Some(&receipt),
                    yes,
                    consent,
                    now,
                ) {
                    Ok((value, line)) => {
                        human.push_str(&line);
                        human.push('\n');
                        results.push(value);
                    }
                    Err(failure) => return failure.print(global),
                }
            }
            ok(global, &json!({ "updated": results }), &human)
        }
    }
}

pub(super) struct Failure {
    code: &'static str,
    message: String,
    details: Option<Value>,
}

impl Failure {
    fn new(code: &'static str, message: impl Into<String>) -> Failure {
        Failure { code, message: message.into(), details: None }
    }

    fn print(self, global: &GlobalArgs) -> i32 {
        fail(global, self.code, self.message, self.details)
    }
}

impl From<cmux_customize::Error> for Failure {
    fn from(error: cmux_customize::Error) -> Failure {
        Failure::new(error.code(), error.to_string())
    }
}

/// Installs `reference`, or updates the install `previous` names.
#[allow(clippy::too_many_arguments)]
fn install(
    global: &GlobalArgs,
    customize: &Customize,
    git: &Git,
    tier: Tier,
    reference: &RepoRef,
    previous: Option<&Receipt>,
    yes: bool,
    consent: &mut Consent,
    now: u64,
) -> Result<(Value, String), Failure> {
    let resolved = git.resolve(reference).map_err(|why| Failure::new("community.fetch", why))?;
    if let Some(previous) = previous.filter(|p| p.commit == resolved.commit) {
        let line =
            format!("{} {} is up to date ({})", tier.name(), previous.id, short(&previous.commit));
        return Ok((
            json!({ "id": previous.id, "commit": previous.commit, "changed": false }),
            line,
        ));
    }
    let staged = tempfile::tempdir().map_err(|e| Failure::new("community.io", e.to_string()))?;
    let sha256 = git
        .fetch_files(reference, &resolved.commit, staged.path())
        .map_err(|why| Failure::new("community.fetch", why))?;
    let package = community::read_package(staged.path())?;
    if package.tier != tier {
        return Err(Failure::new(
            "community.tier",
            format!(
                "{} is a {}, not a {}: `cmux {} install {}`",
                reference.canonical(),
                package.tier.name(),
                tier.name(),
                package.tier.name(),
                reference.reference()
            ),
        ));
    }
    community::check_id(&package, &reference.owner)?;
    community::check_engines(&package, super::machine_server::release_version())?;
    let receipt = Receipt {
        tier,
        id: package.id.clone(),
        name: package.name.clone(),
        entry: package.profile.name.clone(),
        reference: reference.canonical(),
        repository: reference.repository_url(),
        git_ref: reference.git_ref.clone(),
        commit: resolved.commit,
        tag: resolved.tag,
        version: package.version.clone(),
        sha256,
        installed_ms: now,
    };
    let reviewed = git.reviewed(tier, reference);
    let verb = if previous.is_some() { "Update" } else { "Install" };
    let card = community::card(verb, &package, &receipt, reviewed);
    if !yes && !consent.ask(&card, global) {
        return Err(Failure {
            code: "community.needs_consent",
            message: format!("{card}\nNothing was changed. Pass --yes to {}.", verb.to_lowercase()),
            details: Some(json!({ "card": card, "reviewed": reviewed })),
        });
    }
    let change =
        customize.community_put(&package, receipt.clone(), previous.is_none(), "cli", now)?;
    let mut human = format!(
        "{} {} {} ({} @ {})",
        if previous.is_some() { "updated" } else { "installed" },
        tier.name(),
        package.name,
        receipt.reference,
        receipt.tag.clone().unwrap_or_else(|| short(&receipt.commit).to_owned())
    );
    if tier == Tier::Theme {
        human.push_str(&format!("; theme files: {}", package.themes.join(", ")));
        if !package.art.images.is_empty() {
            human.push_str(&format!("; {} images", package.art.images.len()));
        }
        if !package.art.applied.is_empty() {
            human.push_str(&format!("\n  applied: {}", package.art.applied.join(", ")));
        }
        if !package.art.pending.is_empty() {
            human.push_str(&format!(
                "\n  not applied yet (no cmux setting): {}",
                package.art.pending.join(", ")
            ));
        }
    }
    human.push_str(&format!(
        "\n  undo: cmux {} remove {}   (or cmux customize library off {})",
        tier.name(),
        package.id,
        receipt.entry
    ));
    let value = json!({
        "card": card,
        "reviewed": reviewed,
        "changed": true,
        "receipt": receipt,
        "themes": package.themes,
        "images": package.art.images.len(),
        "applied": package.art.applied,
        "pending": package.art.pending,
        "change": change,
    });
    Ok((value, human))
}

fn short(commit: &str) -> &str {
    commit.get(..7).unwrap_or(commit)
}

/// A parsed reference: `[https://]HOST/OWNER/REPO[/PATH][@REF]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct RepoRef {
    pub host: String,
    pub owner: String,
    pub repo: String,
    pub path: String,
    pub git_ref: Option<String>,
}

fn segment_ok(segment: &str) -> bool {
    !segment.is_empty()
        && segment.len() <= 100
        && !segment.starts_with(['.', '-'])
        && segment.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

impl RepoRef {
    pub fn parse(input: &str) -> Result<RepoRef, String> {
        let text = input.trim();
        let bad = |why: &str| Err(format!("{text}: {why}"));
        if text.is_empty()
            || text.len() > 512
            || text.chars().any(|c| c.is_whitespace() || c.is_control())
        {
            return bad("not a repository reference (HOST/OWNER/REPO[/PATH][@REF])");
        }
        let rest = match text.strip_prefix("https://") {
            Some(rest) => rest,
            None if text.contains("://") || text.starts_with("git@") => {
                return bad("only https repositories install (HOST/OWNER/REPO)");
            }
            None => text,
        };
        let (location, git_ref) = match rest.split_once('@') {
            Some((location, git_ref)) => (location, Some(git_ref.to_owned())),
            None => (rest, None),
        };
        let segments: Vec<&str> = location.trim_end_matches('/').split('/').collect();
        let [host, owner, repo, path @ ..] = segments.as_slice() else {
            return bad("name the repository as HOST/OWNER/REPO");
        };
        let host = host.to_ascii_lowercase();
        if !host.contains('.')
            || host.parse::<std::net::IpAddr>().is_ok()
            || !host.split('.').all(|label| {
                !label.is_empty() && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
            })
        {
            return bad("the host is not a public host name");
        }
        let owner = (*owner).to_owned();
        let repo = repo.trim_end_matches(".git").to_owned();
        if !segment_ok(&owner) || !segment_ok(&repo) {
            return bad("the owner or repository name has characters a repository cannot have");
        }
        let path: Vec<&str> = path.to_vec();
        if path.iter().any(|segment| !segment_ok(segment)) {
            return bad("the path has an empty, hidden or unusual directory name");
        }
        if let Some(git_ref) = &git_ref {
            let fine = !git_ref.is_empty()
                && git_ref.len() <= 200
                && !git_ref.starts_with(['-', '/', '.'])
                && !git_ref.contains("..")
                && git_ref
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/'));
            if !fine {
                return bad("the ref has characters a branch or tag cannot have");
            }
        }
        Ok(RepoRef { host, owner, repo, path: path.join("/"), git_ref })
    }

    /// `HOST/OWNER/REPO[/PATH]`.
    pub fn canonical(&self) -> String {
        let mut out = format!("{}/{}/{}", self.host, self.owner, self.repo);
        if !self.path.is_empty() {
            out.push('/');
            out.push_str(&self.path);
        }
        out
    }

    /// `HOST/OWNER/REPO[/PATH][@REF]`.
    pub fn reference(&self) -> String {
        match &self.git_ref {
            Some(git_ref) => format!("{}@{git_ref}", self.canonical()),
            None => self.canonical(),
        }
    }

    pub fn repository_url(&self) -> String {
        format!("https://{}/{}/{}", self.host, self.owner, self.repo)
    }
}

/// What a reference pins.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Resolved {
    pub commit: String,
    pub tag: Option<String>,
}

fn is_commit(text: &str) -> bool {
    text.len() == 40 && text.chars().all(|c| c.is_ascii_hexdigit())
}

/// A version tag: the manifest version, `1.2.0` or `v1.2.0`.
fn version_of(tag: &str) -> Option<(u64, u64, u64)> {
    let mut parts = tag.strip_prefix('v').unwrap_or(tag).split('.');
    let triple =
        (parts.next()?.parse().ok()?, parts.next()?.parse().ok()?, parts.next()?.parse().ok()?);
    parts.next().is_none().then_some(triple)
}

/// `git ls-remote` output: the commit `git_ref` names (no ref: the newest
/// version tag, else HEAD), and the tag when it is one.
pub(super) fn resolve_in(listing: &str, git_ref: Option<&str>) -> Result<Resolved, String> {
    let mut head = None;
    let mut tags: Vec<(String, String)> = Vec::new();
    let mut heads: Vec<(String, String)> = Vec::new();
    for line in listing.lines() {
        let Some((sha, name)) = line.split_once('\t') else { continue };
        if !is_commit(sha) {
            continue;
        }
        if name == "HEAD" {
            head = Some(sha.to_owned());
        } else if let Some(tag) = name.strip_prefix("refs/tags/") {
            // A peeled annotated tag (`^{}`) names the commit; it wins.
            match tag.strip_suffix("^{}") {
                Some(tag) => {
                    tags.retain(|(have, _)| have != tag);
                    tags.push((tag.to_owned(), sha.to_owned()));
                }
                None if !tags.iter().any(|(have, _)| have == tag) => {
                    tags.push((tag.to_owned(), sha.to_owned()));
                }
                None => {}
            }
        } else if let Some(branch) = name.strip_prefix("refs/heads/") {
            heads.push((branch.to_owned(), sha.to_owned()));
        }
    }
    match git_ref {
        None => match tags.iter().filter_map(|(tag, sha)| Some((version_of(tag)?, tag, sha))).max()
        {
            Some((_, tag, sha)) => Ok(Resolved { commit: sha.clone(), tag: Some(tag.clone()) }),
            None => head.map(|commit| Resolved { commit, tag: None }).ok_or_else(|| {
                "the repository has no default branch and no version tag".to_owned()
            }),
        },
        Some(git_ref) if is_commit(git_ref) => {
            Ok(Resolved { commit: git_ref.to_ascii_lowercase(), tag: None })
        }
        Some(git_ref) => {
            if let Some((tag, sha)) = tags.iter().find(|(tag, _)| tag == git_ref) {
                return Ok(Resolved { commit: sha.clone(), tag: Some(tag.clone()) });
            }
            heads
                .iter()
                .find(|(branch, _)| branch == git_ref)
                .map(|(_, sha)| Resolved { commit: sha.clone(), tag: None })
                .ok_or_else(|| format!("the repository has no branch or tag {git_ref}"))
        }
    }
}

/// `git`, run with no prompt, no system config, https only (tests: also
/// local paths), and a stall limit.
pub(super) struct Git {
    /// Tests: the clone URL of a reference is `<base>/OWNER/REPO` on disk.
    local_base: Option<PathBuf>,
}

impl Git {
    fn network() -> Git {
        Git { local_base: None }
    }

    #[cfg(test)]
    pub(super) fn local(base: &Path) -> Git {
        Git { local_base: Some(base.to_path_buf()) }
    }

    fn clone_url(&self, reference: &RepoRef) -> String {
        match &self.local_base {
            Some(base) => {
                base.join(&reference.owner).join(&reference.repo).to_string_lossy().into_owned()
            }
            None => format!("{}.git", reference.repository_url()),
        }
    }

    fn run(&self, dir: Option<&Path>, args: &[&str]) -> Result<Vec<u8>, String> {
        let mut command = Command::new("git");
        command.args(["-c", "protocol.allow=never", "-c", "protocol.https.allow=always"]);
        if self.local_base.is_some() {
            command.args(["-c", "protocol.file.allow=always"]);
        }
        command.args([
            "-c",
            "http.lowSpeedLimit=1000",
            "-c",
            "http.lowSpeedTime=30",
            "-c",
            "core.hooksPath=/dev/null",
        ]);
        if let Some(dir) = dir {
            command.arg("-C").arg(dir);
        }
        let output = command
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("git is needed to install from a repository: {e}"))?;
        if output.status.success() {
            Ok(output.stdout)
        } else {
            Err(format!("git: {}", String::from_utf8_lossy(&output.stderr).trim()))
        }
    }

    pub(super) fn resolve(&self, reference: &RepoRef) -> Result<Resolved, String> {
        let url = self.clone_url(reference);
        let listing =
            self.run(None, &["ls-remote", "--", &url, "HEAD", "refs/tags/*", "refs/heads/*"])?;
        resolve_in(&String::from_utf8_lossy(&listing), reference.git_ref.as_deref())
            .map_err(|why| format!("{}: {why}", reference.canonical()))
    }

    /// Fetches `commit` and writes the files a theme or snippet installs
    /// (under the reference's path) into `dest`; answers the SHA-256 of
    /// what it wrote (each path and its content hash, sorted).
    pub(super) fn fetch_files(
        &self,
        reference: &RepoRef,
        commit: &str,
        dest: &Path,
    ) -> Result<String, String> {
        let scratch = tempfile::tempdir().map_err(|e| e.to_string())?;
        let repo = scratch.path();
        self.run(None, &["init", "-q", "--bare", &repo.to_string_lossy()])?;
        let url = self.clone_url(reference);
        self.run(Some(repo), &["fetch", "-q", "--depth", "1", "--no-tags", "--", &url, commit])
            .map_err(|why| format!("{}: fetching {commit}: {why}", reference.canonical()))?;
        let prefix =
            if reference.path.is_empty() { String::new() } else { format!("{}/", reference.path) };
        let listing = self.run(Some(repo), &["ls-tree", "-r", "-l", "--full-tree", commit])?;
        let mut wanted: Vec<(String, u64)> = Vec::new();
        for line in String::from_utf8_lossy(&listing).lines() {
            // `MODE TYPE SHA SIZE\tPATH`
            let Some((meta, path)) = line.split_once('\t') else { continue };
            let fields: Vec<&str> = meta.split_whitespace().collect();
            let [mode, "blob", _, size] = fields.as_slice() else { continue };
            if *mode != "100644" && *mode != "100755" {
                continue; // no links, no submodules
            }
            let Some(relative) = path.strip_prefix(&prefix) else { continue };
            let installs = relative == community::THEME_MARKER
                || relative == community::SNIPPET_MARKER
                || SNIPPET_FILES.contains(&relative)
                || relative
                    .strip_prefix("themes/")
                    .is_some_and(|name| !name.contains('/') && name.ends_with(".json"))
                || community::art::is_art_path(relative);
            if installs {
                wanted.push((relative.to_owned(), size.parse().unwrap_or(u64::MAX)));
            }
        }
        let most = community::MAX_THEMES + SNIPPET_FILES.len() + 2 + community::art::MAX_IMAGES;
        if wanted.len() > most {
            return Err(format!(
                "{}: too many files to be a theme or snippet",
                reference.canonical()
            ));
        }
        let mut digest = Vec::new();
        let mut art_bytes: u64 = 0;
        for (relative, size) in wanted {
            let cap = if community::art::is_art_path(&relative) {
                art_bytes = art_bytes.saturating_add(size);
                if art_bytes > community::art::MAX_ART_BYTES {
                    return Err(format!(
                        "{}: images larger than {} MiB together",
                        reference.canonical(),
                        community::art::MAX_ART_BYTES / (1024 * 1024)
                    ));
                }
                community::art::MAX_IMAGE_BYTES
            } else {
                community::MAX_MARKER_BYTES
            };
            if size > cap {
                return Err(format!("{relative}: larger than {} KiB", cap / 1024));
            }
            let bytes = self
                .run(Some(repo), &["cat-file", "blob", &format!("{commit}:{prefix}{relative}")])?;
            let file = dest.join(&relative);
            if let Some(parent) = file.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            std::fs::write(&file, &bytes).map_err(|e| e.to_string())?;
            digest.push(format!("{relative}\0{}", hex(&Sha256::digest(&bytes))));
        }
        digest.sort();
        Ok(hex(&Sha256::digest(digest.join("\n").as_bytes())))
    }

    /// Whether the registry repository's list for `tier` lists this
    /// repository (and path): best effort; no answer is not reviewed.
    fn reviewed(&self, tier: Tier, reference: &RepoRef) -> bool {
        if self.local_base.is_some() {
            return false;
        }
        let Ok(scratch) = tempfile::tempdir() else { return false };
        let repo = scratch.path();
        let list = format!("{}s.json", tier.name());
        let text = self
            .run(None, &["init", "-q", "--bare", &repo.to_string_lossy()])
            .and_then(|_| {
                self.run(Some(repo), &["fetch", "-q", "--depth", "1", "--", REGISTRY_REPO, "main"])
            })
            .and_then(|_| {
                self.run(Some(repo), &["cat-file", "blob", &format!("FETCH_HEAD:{list}")])
            });
        text.is_ok_and(|text| listed(&String::from_utf8_lossy(&text), reference))
    }
}

/// Whether a registry list (`[{repo, path?}, ...]`) names `reference`.
pub(super) fn listed(list: &str, reference: &RepoRef) -> bool {
    let Ok(Value::Array(entries)) = serde_json::from_str::<Value>(list) else { return false };
    let want = format!("{}/{}/{}", reference.host, reference.owner, reference.repo);
    entries.iter().any(|entry| {
        let Some(repo) = entry["repo"].as_str() else { return false };
        let named = match repo.strip_prefix("https://") {
            Some(url) => url.trim_end_matches('/').trim_end_matches(".git").to_owned(),
            None => format!("github.com/{repo}"),
        };
        named.eq_ignore_ascii_case(&want)
            && entry["path"].as_str().unwrap_or_default().trim_matches('/') == reference.path
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
#[path = "community/tests.rs"]
mod tests;

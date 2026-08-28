//! Screen-detection manifest engine.
//!
//! Ported from herdrdev/herdr `src/detect/manifest.rs` at commit
//! 7b675f42af35508eab66ac42fe1598628597a893 (Apache-2.0, see
//! `vendor/herdr-manifests/LICENSE`), modified by manaflow: bundled
//! manifests only (no remote updates, no local overrides), agents are
//! identified by manifest id/alias strings instead of a closed enum, and
//! the explain machinery is trimmed to what the detector consumes.

use std::sync::OnceLock;

use regex::Regex;
use serde::Deserialize;

/// Highest herdr manifest engine version whose semantics this port covers.
pub(crate) const SCREEN_DETECT_ENGINE_VERSION: u32 = 3;

const MAX_RULES_PER_MANIFEST: usize = 128;
const MAX_GATE_DEPTH: usize = 8;
const MAX_TOTAL_GATES: usize = 512;
const MAX_MATCHERS_PER_GATE: usize = 32;
const MAX_TOTAL_MATCHERS: usize = 1024;
const MAX_MATCHER_CHARS: usize = 512;

/// Detection states a manifest rule can assign to a screen snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ScreenState {
    Idle,
    Working,
    Blocked,
    Unknown,
}

/// Screen snapshot plus OSC-derived strings. Empty `osc_title` /
/// `osc_progress` behave exactly like the pre-OSC herdr engine.
#[derive(Debug, Clone, Copy)]
pub(crate) struct DetectionInput<'a> {
    pub(crate) screen: &'a str,
    pub(crate) osc_title: &'a str,
    pub(crate) osc_progress: &'a str,
}

/// What one manifest evaluation concluded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Detection {
    pub(crate) state: ScreenState,
    /// The screen shows an agent-owned viewer (transcript scroll etc.);
    /// the previous state must be kept.
    pub(crate) skip_state_update: bool,
    /// Matched rule id, absent when the known-agent idle fallback applied.
    pub(crate) matched_rule: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub(crate) struct AgentManifest {
    id: String,
    #[serde(rename = "version")]
    _version: Option<String>,
    min_engine_version: Option<u32>,
    #[serde(rename = "updated_at")]
    _updated_at: Option<String>,
    #[serde(default)]
    aliases: Vec<String>,
    #[serde(default)]
    rules: Vec<ManifestRule>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
struct ManifestRule {
    id: String,
    state: Option<ManifestState>,
    #[serde(default)]
    priority: i32,
    #[serde(default = "default_region")]
    region: String,
    #[serde(default)]
    visible_idle: bool,
    #[serde(default)]
    visible_blocker: bool,
    #[serde(default)]
    visible_working: bool,
    #[serde(default)]
    skip_state_update: bool,
    #[serde(default)]
    all: Vec<ManifestGate>,
    #[serde(default)]
    any: Vec<ManifestGate>,
    #[serde(default, rename = "not")]
    not_gate: Vec<ManifestGate>,
    #[serde(default)]
    contains: Vec<String>,
    #[serde(default)]
    regex: Vec<String>,
    #[serde(default)]
    line_regex: Vec<String>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
struct ManifestGate {
    #[serde(default)]
    all: Vec<ManifestGate>,
    #[serde(default)]
    any: Vec<ManifestGate>,
    #[serde(default, rename = "not")]
    not_gate: Vec<ManifestGate>,
    #[serde(default)]
    contains: Vec<String>,
    #[serde(default)]
    regex: Vec<String>,
    #[serde(default)]
    line_regex: Vec<String>,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ManifestState {
    Idle,
    Working,
    Blocked,
    Unknown,
}

impl From<ManifestState> for ScreenState {
    fn from(value: ManifestState) -> Self {
        match value {
            ManifestState::Idle => ScreenState::Idle,
            ManifestState::Working => ScreenState::Working,
            ManifestState::Blocked => ScreenState::Blocked,
            ManifestState::Unknown => ScreenState::Unknown,
        }
    }
}

fn default_region() -> String {
    "whole_recent".to_string()
}

#[derive(Debug, Clone)]
struct CompiledGate {
    all: Vec<CompiledGate>,
    any: Vec<CompiledGate>,
    not_gate: Vec<CompiledGate>,
    contains: Vec<String>,
    regex: Vec<Regex>,
    line_regex: Vec<Regex>,
}

/// One agent manifest with its rule gates compiled to regex matchers.
#[derive(Debug, Clone)]
pub(crate) struct CompiledManifest {
    manifest: AgentManifest,
    compiled_rules: Vec<CompiledGate>,
}

impl CompiledManifest {
    pub(crate) fn id(&self) -> &str {
        &self.manifest.id
    }

    /// True when a process name equals the manifest id or one of its
    /// aliases after path/basename and extension normalization.
    pub(crate) fn matches_process_name(&self, process_name: &str) -> bool {
        let name = normalized_agent_lookup_name(path_basename(process_name));
        name == self.manifest.id
            || self.manifest.aliases.iter().any(|alias| normalized_agent_lookup_name(alias) == name)
    }

    /// Evaluate every rule against the snapshot; the highest-priority match
    /// wins (first rule wins a priority tie). No match falls back to `Idle`:
    /// a known agent showing none of its working/blocked chrome is at rest
    /// (herdr's `default_known_agent_idle_fallback`).
    pub(crate) fn detect(&self, input: DetectionInput<'_>) -> Detection {
        let mut matched: Option<&ManifestRule> = None;
        for (rule, compiled) in self.manifest.rules.iter().zip(&self.compiled_rules) {
            let region_text = region(input, &rule.region);
            if !compiled_gate_matches_text(compiled, region_text) {
                continue;
            }
            match matched {
                Some(previous) if previous.priority >= rule.priority => {}
                _ => matched = Some(rule),
            }
        }
        let Some(rule) = matched else {
            return Detection {
                state: ScreenState::Idle,
                skip_state_update: false,
                matched_rule: None,
            };
        };
        Detection {
            state: rule.state.map(ScreenState::from).unwrap_or(ScreenState::Unknown),
            skip_state_update: rule.skip_state_update,
            matched_rule: Some(rule.id.clone()),
        }
    }
}

fn compiled_gate_matches_text(gate: &CompiledGate, text: &str) -> bool {
    let lower_text = text.to_lowercase();
    compiled_gate_matches(gate, text, &lower_text)
}

fn compiled_gate_matches(gate: &CompiledGate, text: &str, lower_text: &str) -> bool {
    if !gate.contains.iter().all(|needle| lower_text.contains(needle)) {
        return false;
    }
    if !gate.regex.iter().all(|regex| regex.is_match(text)) {
        return false;
    }
    if !gate.line_regex.iter().all(|regex| text.lines().any(|line| regex.is_match(line))) {
        return false;
    }
    if !gate.all.iter().all(|nested| compiled_gate_matches(nested, text, lower_text)) {
        return false;
    }
    if !gate.any.is_empty()
        && !gate.any.iter().any(|nested| compiled_gate_matches(nested, text, lower_text))
    {
        return false;
    }
    if gate.not_gate.iter().any(|nested| compiled_gate_matches(nested, text, lower_text)) {
        return false;
    }
    true
}

fn normalized_agent_lookup_name(name: &str) -> String {
    let mut name = name.trim().to_lowercase();
    for suffix in [".exe", ".cmd", ".bat", ".ps1", ".js"] {
        if name.ends_with(suffix) {
            name.truncate(name.len() - suffix.len());
            break;
        }
    }
    name
}

fn path_basename(path: &str) -> &str {
    path.rsplit(['/', '\\']).find(|component| !component.is_empty()).unwrap_or(path)
}

/// Every bundled manifest, keyed for foreground-process identification.
#[derive(Debug)]
pub(crate) struct ManifestSet {
    manifests: Vec<CompiledManifest>,
}

/// The vendored herdr manifests (see `vendor/herdr-manifests/README.md`
/// for the upstream pin). Compile-time embedded; never fetched.
const BUNDLED_MANIFESTS: &[(&str, &str)] = &[
    ("amp", include_str!("../../../../vendor/herdr-manifests/amp.toml")),
    ("agy", include_str!("../../../../vendor/herdr-manifests/antigravity.toml")),
    ("claude", include_str!("../../../../vendor/herdr-manifests/claude.toml")),
    ("cline", include_str!("../../../../vendor/herdr-manifests/cline.toml")),
    ("codex", include_str!("../../../../vendor/herdr-manifests/codex.toml")),
    ("cursor", include_str!("../../../../vendor/herdr-manifests/cursor.toml")),
    ("devin", include_str!("../../../../vendor/herdr-manifests/devin.toml")),
    ("droid", include_str!("../../../../vendor/herdr-manifests/droid.toml")),
    ("gemini", include_str!("../../../../vendor/herdr-manifests/gemini.toml")),
    ("grok", include_str!("../../../../vendor/herdr-manifests/grok.toml")),
    ("hermes", include_str!("../../../../vendor/herdr-manifests/hermes.toml")),
    ("kilo", include_str!("../../../../vendor/herdr-manifests/kilo.toml")),
    ("kimi", include_str!("../../../../vendor/herdr-manifests/kimi.toml")),
    ("kiro", include_str!("../../../../vendor/herdr-manifests/kiro.toml")),
    ("maki", include_str!("../../../../vendor/herdr-manifests/maki.toml")),
    ("muse", include_str!("../../../../vendor/herdr-manifests/muse.toml")),
    ("opencode", include_str!("../../../../vendor/herdr-manifests/opencode.toml")),
    ("pi", include_str!("../../../../vendor/herdr-manifests/pi.toml")),
    ("qodercli", include_str!("../../../../vendor/herdr-manifests/qodercli.toml")),
    ("qwen", include_str!("../../../../vendor/herdr-manifests/qwen.toml")),
    ("copilot", include_str!("../../../../vendor/herdr-manifests/github-copilot.toml")),
];

static BUNDLED_SET: OnceLock<ManifestSet> = OnceLock::new();

impl ManifestSet {
    /// The embedded manifest set. Bundled files are pinned by unit tests,
    /// so a compile failure here is a vendoring bug, not a runtime input.
    pub(crate) fn bundled() -> &'static ManifestSet {
        BUNDLED_SET.get_or_init(|| {
            Self::from_sources(BUNDLED_MANIFESTS)
                .expect("bundled screen-detection manifests are pinned valid by tests")
        })
    }

    pub(crate) fn from_sources(sources: &[(&str, &str)]) -> Result<Self, String> {
        let manifests = sources
            .iter()
            .map(|(label, content)| {
                compile_manifest_source(content)
                    .map_err(|err| format!("bundled manifest {label} is invalid: {err}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self { manifests })
    }

    pub(crate) fn manifests(&self) -> impl Iterator<Item = &CompiledManifest> {
        self.manifests.iter()
    }

    /// The manifest whose id or aliases match the foreground process name,
    /// or `None` when the process is not a supported agent.
    pub(crate) fn identify(&self, process_name: &str) -> Option<&CompiledManifest> {
        self.manifests.iter().find(|manifest| manifest.matches_process_name(process_name))
    }
}

pub(crate) fn compile_manifest_source(content: &str) -> Result<CompiledManifest, String> {
    let manifest = toml::from_str::<AgentManifest>(content).map_err(|err| err.to_string())?;
    validate_manifest(&manifest)?;
    let compiled_rules = compile_manifest(&manifest)?;
    Ok(CompiledManifest { manifest, compiled_rules })
}

fn validate_manifest(manifest: &AgentManifest) -> Result<(), String> {
    if manifest.id.trim().is_empty() {
        return Err("manifest id must not be empty".to_string());
    }
    if let Some(version) = manifest.min_engine_version
        && version > SCREEN_DETECT_ENGINE_VERSION
    {
        return Err(format!(
            "manifest requires engine {version}, this engine is {SCREEN_DETECT_ENGINE_VERSION}"
        ));
    }
    if manifest.rules.is_empty() {
        return Err("manifest must contain at least one rule".to_string());
    }
    if manifest.rules.len() > MAX_RULES_PER_MANIFEST {
        return Err(format!(
            "manifest contains {} rules, max is {MAX_RULES_PER_MANIFEST}",
            manifest.rules.len()
        ));
    }

    let mut complexity = ManifestComplexity::default();
    for rule in &manifest.rules {
        if rule.id.trim().is_empty() {
            return Err("manifest rule id must not be empty".to_string());
        }
        if rule.skip_state_update {
            if rule.state != Some(ManifestState::Unknown) {
                return Err(format!(
                    "rule {} uses skip_state_update without state = \"unknown\"",
                    rule.id
                ));
            }
            if rule.visible_idle || rule.visible_blocker || rule.visible_working {
                return Err(format!(
                    "rule {} uses skip_state_update with visible state evidence",
                    rule.id
                ));
            }
        }
        validate_region_name(&rule.region)
            .map_err(|err| format!("rule {} uses invalid region: {err}", rule.id))?;
        validate_gate(&manifest_gate_from_rule(rule), "rule", 0, &mut complexity)
            .map_err(|err| format!("rule {} has invalid matcher gates: {err}", rule.id))?;
    }
    Ok(())
}

#[derive(Default)]
struct ManifestComplexity {
    total_gates: usize,
    total_matchers: usize,
}

fn validate_gate(
    gate: &ManifestGate,
    context: &str,
    depth: usize,
    complexity: &mut ManifestComplexity,
) -> Result<(), String> {
    if depth > MAX_GATE_DEPTH {
        return Err(format!("{context} exceeds max gate depth {MAX_GATE_DEPTH}"));
    }
    complexity.total_gates += 1;
    if complexity.total_gates > MAX_TOTAL_GATES {
        return Err(format!("manifest exceeds max gate count {MAX_TOTAL_GATES}"));
    }
    validate_matcher_limits(gate, context, complexity)?;
    if !gate_has_positive_matcher(gate) {
        return Err(format!("{context} must contain a positive matcher"));
    }
    validate_regex_patterns(&gate.regex, context, "regex")?;
    validate_regex_patterns(&gate.line_regex, context, "line_regex")?;
    for nested in &gate.all {
        validate_gate(nested, "all gate", depth + 1, complexity)?;
    }
    for nested in &gate.any {
        validate_gate(nested, "any gate", depth + 1, complexity)?;
    }
    for nested in &gate.not_gate {
        if !gate_has_any_matcher(nested) {
            return Err(format!("{context} contains an empty not gate"));
        }
        validate_not_gate(nested, depth + 1, complexity)?;
    }
    Ok(())
}

fn validate_not_gate(
    gate: &ManifestGate,
    depth: usize,
    complexity: &mut ManifestComplexity,
) -> Result<(), String> {
    if depth > MAX_GATE_DEPTH {
        return Err(format!("not gate exceeds max gate depth {MAX_GATE_DEPTH}"));
    }
    complexity.total_gates += 1;
    if complexity.total_gates > MAX_TOTAL_GATES {
        return Err(format!("manifest exceeds max gate count {MAX_TOTAL_GATES}"));
    }
    validate_matcher_limits(gate, "not gate", complexity)?;
    if !gate_has_any_matcher(gate) {
        return Err("not gate must contain a matcher".to_string());
    }
    validate_regex_patterns(&gate.regex, "not gate", "regex")?;
    validate_regex_patterns(&gate.line_regex, "not gate", "line_regex")?;
    for nested in &gate.all {
        validate_gate(nested, "not all gate", depth + 1, complexity)?;
    }
    for nested in &gate.any {
        validate_gate(nested, "not any gate", depth + 1, complexity)?;
    }
    for nested in &gate.not_gate {
        validate_not_gate(nested, depth + 1, complexity)?;
    }
    Ok(())
}

fn validate_matcher_limits(
    gate: &ManifestGate,
    context: &str,
    complexity: &mut ManifestComplexity,
) -> Result<(), String> {
    let matcher_count = gate.contains.len() + gate.regex.len() + gate.line_regex.len();
    if matcher_count > MAX_MATCHERS_PER_GATE {
        return Err(format!(
            "{context} has {matcher_count} direct matchers, max is {MAX_MATCHERS_PER_GATE}"
        ));
    }
    complexity.total_matchers += matcher_count;
    if complexity.total_matchers > MAX_TOTAL_MATCHERS {
        return Err(format!("manifest exceeds max matcher count {MAX_TOTAL_MATCHERS}"));
    }
    for value in gate.contains.iter().chain(gate.regex.iter()).chain(gate.line_regex.iter()) {
        if value.chars().count() > MAX_MATCHER_CHARS {
            return Err(format!("{context} matcher exceeds max length {MAX_MATCHER_CHARS}"));
        }
    }
    Ok(())
}

fn validate_regex_patterns(patterns: &[String], context: &str, field: &str) -> Result<(), String> {
    for pattern in patterns {
        Regex::new(pattern).map_err(|err| {
            format!("{context} contains invalid {field} pattern {pattern:?}: {err}")
        })?;
    }
    Ok(())
}

fn gate_has_positive_matcher(gate: &ManifestGate) -> bool {
    !gate.contains.is_empty()
        || !gate.regex.is_empty()
        || !gate.line_regex.is_empty()
        || !gate.all.is_empty()
        || !gate.any.is_empty()
}

fn gate_has_any_matcher(gate: &ManifestGate) -> bool {
    gate_has_positive_matcher(gate) || !gate.not_gate.is_empty()
}

fn manifest_gate_from_rule(rule: &ManifestRule) -> ManifestGate {
    ManifestGate {
        all: rule.all.clone(),
        any: rule.any.clone(),
        not_gate: rule.not_gate.clone(),
        contains: rule.contains.clone(),
        regex: rule.regex.clone(),
        line_regex: rule.line_regex.clone(),
    }
}

fn compile_manifest(manifest: &AgentManifest) -> Result<Vec<CompiledGate>, String> {
    manifest
        .rules
        .iter()
        .map(|rule| {
            compile_gate(&manifest_gate_from_rule(rule))
                .map_err(|err| format!("rule {} could not be compiled: {err}", rule.id))
        })
        .collect()
}

fn validate_region_name(spec: &str) -> Result<(), String> {
    let trimmed = spec.trim();
    match trimmed {
        "whole_recent"
        | "after_last_prompt_marker"
        | "before_current_prompt_marker"
        | "whole_recent_without_current_prompt_marker"
        | "current_prompt_block_marker"
        | "after_current_prompt_block_marker"
        | "prompt_box_body"
        | "above_prompt_box"
        | "last_non_empty_above_prompt_box"
        | "after_last_horizontal_rule"
        | "osc_title"
        | "osc_progress" => Ok(()),
        _ if region_count(trimmed, "bottom_lines").is_some()
            || region_count(trimmed, "bottom_non_empty_lines").is_some()
            || top_region_count(trimmed).is_some() =>
        {
            Ok(())
        }
        _ => Err(trimmed.to_string()),
    }
}

fn region<'a>(input: DetectionInput<'a>, spec: &str) -> &'a str {
    let trimmed = spec.trim();
    // OSC regions source from their dedicated fields, not the screen.
    match trimmed {
        "osc_title" => return input.osc_title,
        "osc_progress" => return input.osc_progress,
        _ => {}
    }
    let content = input.screen;
    match trimmed {
        "whole_recent" => content,
        "after_last_prompt_marker" => after_last_prompt_marker(content),
        "before_current_prompt_marker" => before_current_prompt_marker(content),
        "whole_recent_without_current_prompt_marker" => {
            whole_recent_without_current_prompt_marker(content)
        }
        "current_prompt_block_marker" => current_prompt_block_marker(content).unwrap_or(""),
        "after_current_prompt_block_marker" => {
            after_current_prompt_block_marker(content).unwrap_or("")
        }
        "prompt_box_body" => prompt_box_body(content).unwrap_or(""),
        "above_prompt_box" => above_prompt_box(content),
        "last_non_empty_above_prompt_box" => last_non_empty_line(above_prompt_box(content)),
        "after_last_horizontal_rule" => after_last_horizontal_rule(content),
        _ => {
            if let Some(count) = region_count(trimmed, "bottom_lines") {
                return bottom_lines(content, count);
            }
            if let Some(count) = region_count(trimmed, "bottom_non_empty_lines") {
                return bottom_non_empty_lines(content, count);
            }
            if let Some(count) = top_region_count(trimmed) {
                return top_non_empty_lines(content, count);
            }
            ""
        }
    }
}

fn region_count(spec: &str, name: &str) -> Option<usize> {
    spec.strip_prefix(name)
        .and_then(|rest| rest.strip_prefix('('))
        .and_then(|rest| rest.strip_suffix(')'))
        .and_then(|count| count.parse::<usize>().ok())
}

const MAX_TOP_REGION_LINE_COUNT: usize = u16::MAX as usize;

fn top_region_count(spec: &str) -> Option<usize> {
    let count = spec.strip_prefix("top_non_empty_lines")?.strip_prefix('(')?.strip_suffix(')')?;
    if count.starts_with('0') || !count.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    count.parse::<usize>().ok().filter(|count| *count <= MAX_TOP_REGION_LINE_COUNT)
}

fn bottom_lines(content: &str, count: usize) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(count);
    slice_from_line_index(content, &lines, start)
}

fn bottom_non_empty_lines(content: &str, count: usize) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(start_index) = lines
        .iter()
        .enumerate()
        .rev()
        .filter(|(_, line)| !line.trim().is_empty())
        .take(count)
        .last()
        .map(|(index, _)| index)
    else {
        return "";
    };
    slice_from_line_index(content, &lines, start_index)
}

fn top_non_empty_lines(content: &str, count: usize) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(end_index) = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .take(count)
        .last()
        .map(|(index, _)| index)
    else {
        return "";
    };
    let byte_offset = line_start_offset(content, &lines, end_index + 1);
    &content[..byte_offset]
}

fn after_last_prompt_marker(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(index) = lines.iter().rposition(|line| codex_prompt_line(line)) else {
        return content;
    };
    slice_from_line_index(content, &lines, index + 1)
}

fn before_current_prompt_marker(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(index) = current_codex_prompt_index(&lines) else {
        return content;
    };
    let byte_offset = lines[..index].iter().map(|line| line.len() + 1).sum::<usize>();
    &content[..byte_offset.min(content.len())]
}

fn whole_recent_without_current_prompt_marker(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    if current_codex_prompt_index(&lines).is_some() { "" } else { content }
}

fn current_prompt_block_marker(content: &str) -> Option<&str> {
    let lines: Vec<&str> = content.lines().collect();
    let prompt_index = current_codex_prompt_index(&lines)?;
    lines[..prompt_index].iter().rev().find(|line| codex_block_marker_line(line)).copied()
}

fn after_current_prompt_block_marker(content: &str) -> Option<&str> {
    let lines: Vec<&str> = content.lines().collect();
    let prompt_index = current_codex_prompt_index(&lines)?;
    let block_index = lines[..prompt_index].iter().rposition(|line| codex_block_marker_line(line))?;
    Some(slice_from_line_index(content, &lines, block_index))
}

fn current_codex_prompt_index(lines: &[&str]) -> Option<usize> {
    let prompt_index = lines.iter().rposition(|line| codex_prompt_line(line))?;
    if lines[prompt_index + 1..].iter().any(|line| codex_block_marker_line(line)) {
        return None;
    }
    Some(prompt_index)
}

fn codex_prompt_line(line: &str) -> bool {
    line == "›" || line.starts_with("› ")
}

fn codex_block_marker_line(line: &str) -> bool {
    line.starts_with('•') || line.starts_with('■') || line.starts_with('✗') || line.starts_with('✓')
}

fn prompt_box_body(content: &str) -> Option<&str> {
    let lines: Vec<&str> = content.lines().collect();
    let top = prompt_box_top_border_index(&lines)?;
    let start = line_start_offset(content, &lines, top + 1);
    let end_index = lines[top + 1..]
        .iter()
        .position(|line| is_horizontal_rule(line))
        .map(|relative| top + 1 + relative)
        .unwrap_or(lines.len());
    let end = line_start_offset(content, &lines, end_index);
    Some(&content[start.min(content.len())..end.min(content.len())])
}

fn above_prompt_box(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(top) = prompt_box_top_border_index(&lines) else {
        return content;
    };
    let end = line_start_offset(content, &lines, top);
    &content[..end.min(content.len())]
}

fn after_last_horizontal_rule(content: &str) -> &str {
    let mut last_rule_end = 0usize;
    let mut offset = 0usize;
    for line in content.lines() {
        let next_offset = offset + line.len() + 1;
        if is_horizontal_rule(line) {
            last_rule_end = next_offset.min(content.len());
        }
        offset = next_offset;
    }
    &content[last_rule_end..]
}

fn last_non_empty_line(content: &str) -> &str {
    content.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("")
}

fn prompt_box_top_border_index(lines: &[&str]) -> Option<usize> {
    let mut border_count = 0;
    for index in (0..lines.len()).rev() {
        if is_horizontal_rule(lines[index]) {
            border_count += 1;
            if border_count == 2 {
                return Some(index);
            }
        }
    }
    None
}

fn is_horizontal_rule(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    let rule_chars = trimmed.chars().take_while(|&ch| ch == '─').count();
    if rule_chars == 0 {
        return false;
    }
    let rule_bytes =
        trimmed.char_indices().nth(rule_chars).map(|(index, _)| index).unwrap_or(trimmed.len());
    let suffix = trimmed[rule_bytes..].trim_start();
    suffix.is_empty() || rule_chars >= 3
}

fn slice_from_line_index<'a>(content: &'a str, lines: &[&str], index: usize) -> &'a str {
    let byte_offset = line_start_offset(content, lines, index);
    &content[byte_offset.min(content.len())..]
}

fn line_start_offset(content: &str, lines: &[&str], index: usize) -> usize {
    lines[..index.min(lines.len())]
        .iter()
        .map(|line| line.len() + 1)
        .sum::<usize>()
        .min(content.len())
}

fn compile_gate(gate: &ManifestGate) -> Result<CompiledGate, String> {
    Ok(CompiledGate {
        all: gate.all.iter().map(compile_gate).collect::<Result<_, _>>()?,
        any: gate.any.iter().map(compile_gate).collect::<Result<_, _>>()?,
        not_gate: gate.not_gate.iter().map(compile_gate).collect::<Result<_, _>>()?,
        contains: gate.contains.iter().map(|needle| needle.to_lowercase()).collect(),
        regex: gate
            .regex
            .iter()
            .map(|pattern| Regex::new(pattern).map_err(|err| err.to_string()))
            .collect::<Result<_, _>>()?,
        line_regex: gate
            .line_regex
            .iter()
            .map(|pattern| Regex::new(pattern).map_err(|err| err.to_string()))
            .collect::<Result<_, _>>()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(screen: &str) -> DetectionInput<'_> {
        DetectionInput { screen, osc_title: "", osc_progress: "" }
    }

    #[test]
    fn screen_detect_bundled_manifests_all_parse_and_identify() {
        let set = ManifestSet::bundled();
        let ids: Vec<&str> = set.manifests().map(CompiledManifest::id).collect();
        assert_eq!(ids.len(), 21, "all vendored manifests load: {ids:?}");
        for expected in [
            "amp", "agy", "claude", "cline", "codex", "cursor", "devin", "droid", "gemini",
            "grok", "hermes", "kilo", "kimi", "kiro", "maki", "muse", "opencode", "pi",
            "qodercli", "qwen", "copilot",
        ] {
            assert_eq!(
                set.identify(expected).map(CompiledManifest::id),
                Some(expected),
                "{expected} identifies itself"
            );
        }
    }

    #[test]
    fn screen_detect_identify_normalizes_paths_aliases_and_case() {
        let set = ManifestSet::bundled();
        for (name, id) in [
            ("/opt/homebrew/bin/codex", "codex"),
            ("claude-code", "claude"),
            ("CLAUDE", "claude"),
            ("cursor-agent", "cursor"),
            ("opencode.exe", "opencode"),
            ("github-copilot", "copilot"),
            (r"C:\Users\dev\kiro-cli.exe", "kiro"),
        ] {
            assert_eq!(set.identify(name).map(CompiledManifest::id), Some(id), "{name}");
        }
        for shell in ["bash", "zsh", "vim", "node", "muse-helper", "codex-helper", ""] {
            assert!(set.identify(shell).is_none(), "{shell} is not an agent");
        }
    }

    #[test]
    fn screen_detect_rule_priority_and_gates_pick_the_strongest_match() {
        let manifest = compile_manifest_source(
            r#"
id = "codex"

[[rules]]
id = "low"
state = "idle"
priority = 1
contains = ["match"]

[[rules]]
id = "high"
state = "working"
priority = 10
contains = ["match"]
all = [{ any = [{ regex = ["w[io]n"] }, { contains = ["fallback"] }] }]
not = [{ contains = ["suppressed"] }]

[[rules]]
id = "line"
state = "blocked"
priority = 5
line_regex = ["^prompt: .*\\?$"]
"#,
        )
        .unwrap();

        let matched = manifest.detect(input("a match that won"));
        assert_eq!(matched.state, ScreenState::Working);
        assert_eq!(matched.matched_rule.as_deref(), Some("high"));

        // The not gate suppresses the strong rule; the weak one remains.
        let suppressed = manifest.detect(input("a match that won but suppressed"));
        assert_eq!(suppressed.state, ScreenState::Idle);
        assert_eq!(suppressed.matched_rule.as_deref(), Some("low"));

        // line_regex must match one whole line, not the flattened text.
        let lined = manifest.detect(input("noise\nprompt: continue?\ntail"));
        assert_eq!(lined.state, ScreenState::Blocked);
        let unlined = manifest.detect(input("prompt: continue? trailing"));
        assert_eq!(unlined.state, ScreenState::Idle);
        assert_eq!(unlined.matched_rule, None, "known-agent idle fallback");
    }

    #[test]
    fn screen_detect_regions_scope_matching_to_screen_slices() {
        let manifest = compile_manifest_source(
            r#"
id = "codex"

[[rules]]
id = "tail"
state = "working"
priority = 10
region = "bottom_non_empty_lines(2)"
contains = ["spinner"]

[[rules]]
id = "title"
state = "blocked"
priority = 20
region = "osc_title"
contains = ["action required"]
"#,
        )
        .unwrap();

        let tail = manifest.detect(input("spinner far above\nline\nlast\nend"));
        assert_eq!(tail.state, ScreenState::Idle, "match above the bottom slice is out of scope");
        let hit = manifest.detect(input("above\nline\nspinner here\nend"));
        assert_eq!(hit.state, ScreenState::Working);

        let titled = manifest.detect(DetectionInput {
            screen: "plain",
            osc_title: "⚠ Action Required",
            osc_progress: "",
        });
        assert_eq!(titled.state, ScreenState::Blocked);
    }

    #[test]
    fn screen_detect_codex_manifest_classifies_live_screens() {
        let set = ManifestSet::bundled();
        let codex = set.identify("codex").unwrap();

        let working =
            codex.detect(input("context\n\n• Working (esc to interrupt)\n› \n"));
        assert_eq!(working.state, ScreenState::Working);

        let blocked = codex.detect(input("$ rm -rf build\nAllow command?\n"));
        assert_eq!(blocked.state, ScreenState::Blocked);

        let idle = codex.detect(input("ordinary prompt text"));
        assert_eq!(idle.state, ScreenState::Idle);
        assert!(idle.matched_rule.is_none());

        let viewer = codex.detect(input(
            "› old prompt\ntranscript\n↑/↓ to scroll  pgup/pgdn to page\nhome/end to jump  q to quit  esc to edit prev\n",
        ));
        assert!(viewer.skip_state_update, "transcript viewer keeps the prior state");
    }

    #[test]
    fn screen_detect_manifest_validation_rejects_malformed_sources() {
        for (source, why) in [
            ("id = \"x\"\n", "no rules"),
            (
                "id = \"x\"\n[[rules]]\nid = \"r\"\nstate = \"idle\"\nregion = \"nope\"\ncontains = [\"a\"]\n",
                "unknown region",
            ),
            (
                "id = \"x\"\n[[rules]]\nid = \"r\"\nstate = \"working\"\nskip_state_update = true\ncontains = [\"a\"]\n",
                "skip_state_update requires unknown state",
            ),
            (
                "id = \"x\"\n[[rules]]\nid = \"r\"\nstate = \"idle\"\nregex = [\"(\"]\n",
                "invalid regex",
            ),
            (
                "id = \"x\"\n[[rules]]\nid = \"r\"\nstate = \"idle\"\nsurprise = true\ncontains = [\"a\"]\n",
                "unknown field",
            ),
            (
                "id = \"x\"\nmin_engine_version = 99\n[[rules]]\nid = \"r\"\nstate = \"idle\"\ncontains = [\"a\"]\n",
                "future engine version",
            ),
            (
                "id = \"x\"\n[[rules]]\nid = \"r\"\nstate = \"idle\"\nnot = [{ contains = [\"a\"] }]\n",
                "not-only rule has no positive matcher",
            ),
        ] {
            assert!(compile_manifest_source(source).is_err(), "{why}");
        }
    }
}

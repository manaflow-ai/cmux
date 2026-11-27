//! The `compose` area's ops: who a new message goes to and how a send is routed. The Swift files under
//! `CmuxNextHome/NewMessage/`, `HomeMessageRouting`, `HomeMentions`, `HomeDirectory`, `HomeGroupActions`,
//! `HomeGroupCreation`, `HomeTeamInviteRun`, `HomeComposerCheck` and `HomeTeamSeatImpact` keep the I/O
//! and the words; the rules are here.

pub mod directory;
pub mod draft;
pub mod field;
pub mod group;
pub mod routing;
pub mod text;
pub mod types;

use crate::ops::{OpError, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};

/// This area's op names (without the `compose.` prefix).
pub const OPS: &[&str] = &[
    "address.parse",
    "draft.state",
    "draft.add",
    "draft.commit",
    "draft.deleteBackward",
    "draft.remove",
    "draft.resolve",
    "draft.suggestions",
    "draft.chiefShortcuts",
    "draft.idleSuggestions",
    "draft.existingConversation",
    "field.idleRows",
    "field.typedRows",
    "field.browseRows",
    "field.step",
    "list.show",
    "list.move",
    "list.lines",
    "list.detailKind",
    "routing.chiefConversation",
    "routing.recipients",
    "routing.resolve",
    "routing.compose",
    "routing.quoted",
    "routing.mention",
    "routing.suggestions",
    "mentions.runs",
    "composerCheck.problem",
    "composerSource.submit",
    "composerSource.snapshot",
    "directory.chiefNamed",
    "directory.members",
    "directory.replyValue",
    "directory.renameFailure",
    "directory.archiveOutcome",
    "directory.needsEnsure",
    "directory.sessionScope",
    "directory.channelPlan",
    "directory.makePrimary",
    "group.names",
    "group.member",
    "group.contact",
    "group.info",
    "group.addable",
    "group.namedPeople",
    "group.outcome",
    "group.gate",
    "group.settle",
    "group.removeNamed",
    "group.removalNaming",
    "group.muteGate",
    "group.createSetsReplies",
    "team.seatImpact",
    "team.inviteEmail",
    "team.inviteOutcome",
    "team.inviteAnswer",
];

const SUGGESTION_LIMIT: usize = 8;
const CHIEF_LIMIT: usize = 3;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AddressRequest {
    text: String,
    calling_code: Option<String>,
}

/// Runs `compose.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "address.parse" => {
            let r: AddressRequest = parse(request)?;
            reply(&text::parse_address(&r.text, r.calling_code.as_deref().unwrap_or("1")))
        }
        "draft.state" => reply(&parse::<draft::DraftRequest>(request)?.draft.state()),
        "draft.add" => {
            let r: draft::AddRequest = parse(request)?;
            let mut d = r.draft;
            let before = d.clone();
            d.add(r.recipient);
            let changed = d != before;
            reply(&draft::Changed { draft: d, changed })
        }
        "draft.commit" => {
            let r: draft::ContactsRequest = parse(request)?;
            let mut d = r.draft;
            let changed = d.commit(&r.contacts);
            reply(&draft::Changed { draft: d, changed })
        }
        "draft.deleteBackward" => {
            let mut d = parse::<draft::DraftRequest>(request)?.draft;
            let changed = d.delete_backward();
            reply(&draft::Changed { draft: d, changed })
        }
        "draft.remove" => {
            let r: draft::RemoveRequest = parse(request)?;
            let mut d = r.draft;
            let changed = r.index < d.tokens.len();
            d.remove(r.index);
            reply(&draft::Changed { draft: d, changed })
        }
        "draft.resolve" => {
            let r: draft::ResolveRequest = parse(request)?;
            reply(&draft::resolve(&r.text, &r.contacts))
        }
        "draft.suggestions" => {
            let r: draft::ContactsRequest = parse(request)?;
            reply(&r.draft.suggestions(&r.contacts, r.limit.unwrap_or(SUGGESTION_LIMIT)))
        }
        "draft.chiefShortcuts" => {
            let r: draft::ContactsRequest = parse(request)?;
            reply(&r.draft.chief_shortcuts(&r.contacts, r.limit.unwrap_or(CHIEF_LIMIT)))
        }
        "draft.idleSuggestions" => {
            let r: draft::ContactsRequest = parse(request)?;
            reply(&r.draft.idle_suggestions(&r.contacts, r.limit.unwrap_or(CHIEF_LIMIT)))
        }
        "draft.existingConversation" => {
            let r: draft::ExistingRequest = parse(request)?;
            reply(&r.draft.existing_conversation(&r.rows, r.me.as_deref()))
        }
        "field.idleRows" => {
            let r: field::RowsRequest = parse(request)?;
            let limit = r.chief_limit.unwrap_or(CHIEF_LIMIT);
            reply(&field::idle_rows(&r.draft, &r.contacts, r.has_new_chief, r.has_invite, limit))
        }
        "field.typedRows" => {
            let r: field::RowsRequest = parse(request)?;
            reply(&field::typed_rows(&r.draft, &r.contacts, r.invite_team.as_deref()))
        }
        "field.browseRows" => {
            let r: field::RowsRequest = parse(request)?;
            reply(&field::browse_rows(&r.draft, &r.contacts))
        }
        "field.step" => {
            let r: field::StepRequest = parse(request)?;
            reply(&field::step(r.state, &r.context, r.event))
        }
        "list.show" => {
            let r: field::ShowRequest = parse(request)?;
            reply(&field::ListState::show(r.rows, r.empty_text, r.highlight_first))
        }
        "list.move" => {
            let r: field::MoveRequest = parse(request)?;
            let mut list = r.list;
            list.moved(r.offset);
            reply(&list)
        }
        "list.lines" => reply(&field::lines(&parse::<field::LinesRequest>(request)?.rows)),
        "list.detailKind" => {
            reply(&field::detail_kind(&parse::<field::DetailRequest>(request)?.recipient))
        }
        "routing.chiefConversation" => {
            reply(&parse::<routing::Routing>(request)?.chief_conversation())
        }
        "routing.recipients" => reply(&parse::<routing::Routing>(request)?.recipients()),
        "routing.resolve" => {
            let r: routing::ResolveRequest = parse(request)?;
            reply(&r.routing.resolve(&r.text))
        }
        "routing.compose" => {
            let r: routing::ComposeRequest = parse(request)?;
            if !r.listed {
                return Ok(Value::Null);
            }
            reply(&routing::compose(&r.text, r.own.as_deref().unwrap_or("")))
        }
        "routing.quoted" => reply(&routing::quoted(&parse::<routing::TextRequest>(request)?.text)),
        "routing.mention" => {
            let r: routing::MentionRequest = parse(request)?;
            reply(&routing::mention(&r.title, &r.link))
        }
        "routing.suggestions" => {
            let r: routing::SourceRequest = parse(request)?;
            let source = routing::suggestion_source(&r.source);
            let choices = match source {
                Some(routing::SuggestionSource::Recipients) => Some(r.routing.recipients()),
                Some(routing::SuggestionSource::Members) => {
                    Some(routing::member_choices(&r.members))
                }
                _ => None,
            };
            Ok(json!({"source": source, "choices": choices}))
        }
        "mentions.runs" => {
            let r: routing::RunsRequest = parse(request)?;
            reply(&routing::mention_runs(&r.text, &r.participants))
        }
        "composerCheck.problem" => {
            reply(&routing::attachment_problem(&parse::<routing::ProblemRequest>(request)?.input))
        }
        "composerSource.submit" => {
            let r: routing::SubmitRequest = parse(request)?;
            reply(&routing::source_submit(&r.op, r.conversation.as_deref()))
        }
        "composerSource.snapshot" => reply(&routing::source_snapshot(
            &parse::<routing::SnapshotRequest>(request)?.conversation,
        )),
        _ => call_more(name, request),
    }
}

fn call_more(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "directory.chiefNamed" => {
            let r: directory::ChiefRequest = parse(request)?;
            reply(&directory::chief_named(&r.chiefs, &r.text))
        }
        "directory.members" => {
            let r: directory::MembersRequest = parse(request)?;
            reply(&directory::members(&r.value, r.me.as_deref()))
        }
        "directory.replyValue" => {
            reply(&directory::reply_value(&parse::<directory::ValueRequest>(request)?.value))
        }
        "directory.renameFailure" => {
            reply(&directory::rename_failure(&parse::<directory::FailureRequest>(request)?.error))
        }
        "directory.archiveOutcome" => {
            reply(&directory::archive_outcome(&parse::<directory::FailureRequest>(request)?.error))
        }
        "directory.needsEnsure" => {
            let r: directory::EnsureRequest = parse(request)?;
            reply(&directory::needs_ensure(&r.code, &r.message))
        }
        "directory.sessionScope" => {
            let r: directory::ScopeRequest = parse(request)?;
            let changed =
                r.previous.as_deref().is_some_and(|p| directory::scope_changed(p, &r.key));
            Ok(json!({"scope": directory::session_scope(&r.key), "changed": changed}))
        }
        "directory.channelPlan" => {
            let r: directory::ChannelRequest = parse(request)?;
            Ok(directory::channel_plan(
                &r.title,
                r.chief_name.as_deref(),
                &r.people,
                &r.key,
                &r.conversation,
            ))
        }
        "directory.makePrimary" => reply(&directory::make_primary_sends(
            parse::<directory::PrimaryRequest>(request)?.is_default,
        )),
        "group.names" => reply(&group::names(&parse::<group::NamesRequest>(request)?.list)),
        "group.member" => {
            let r: group::LookupRequest = parse(request)?;
            reply(&r.book.member(&r.text, r.conversation.as_deref().unwrap_or("")))
        }
        "group.contact" => {
            let r: group::LookupRequest = parse(request)?;
            reply(&r.book.contact(&r.text))
        }
        "group.info" => {
            let r: group::InfoRequest = parse(request)?;
            let row = r.book.rows.iter().find(|row| row.id == r.conversation);
            reply(&row.map(|row| group::info(row, r.book.me.as_deref(), r.can_mute, r.muted)))
        }
        "group.addable" => {
            let r: group::LookupRequest = parse(request)?;
            reply(&r.book.addable(r.conversation.as_deref().unwrap_or("")))
        }
        "group.namedPeople" => {
            let r: group::NamedRequest = parse(request)?;
            reply(&group::named_people(
                &r.book,
                &r.list,
                r.conversation.as_deref(),
                r.purpose,
                &r.lookups,
            ))
        }
        "group.outcome" => {
            let r: group::OutcomeRequest = parse(request)?;
            let outcome = group::outcome(&r.rejection, &r.naming, r.removing);
            let succeeded = outcome.succeeded();
            Ok(json!({"outcome": outcome, "succeeded": succeeded}))
        }
        "group.gate" => {
            let r: group::GateRequest = parse(request)?;
            reply(&group::gate(
                &r.book,
                r.change,
                &r.conversation,
                r.text.as_deref(),
                r.person.as_deref(),
            ))
        }
        "group.settle" => {
            let r: group::SettleRequest = parse(request)?;
            reply(&group::settle(r.change, &r.outcome))
        }
        "group.removeNamed" => {
            let r: group::LookupRequest = parse(request)?;
            match group::remove_named(&r.book, &r.text, r.conversation.as_deref().unwrap_or("")) {
                Ok(person) => Ok(json!({"person": person})),
                Err(outcome) => Ok(json!({"outcome": outcome})),
            }
        }
        "group.removalNaming" => {
            let r: group::LookupRequest = parse(request)?;
            reply(&group::removal_naming(&r.book, &r.text, r.conversation.as_deref().unwrap_or("")))
        }
        "group.muteGate" => {
            let r: group::GateRequest = parse(request)?;
            reply(&group::mute_gate(&r.book, &r.conversation, r.can_mute))
        }
        "group.createSetsReplies" => {
            reply(&group::create_sets_replies(parse::<group::RepliesRequest>(request)?.replies))
        }
        "team.seatImpact" => {
            let r: directory::SeatRequest = parse(request)?;
            let impact = directory::seat_impact(&r);
            let allows = impact != directory::SeatImpact::NotAllowed;
            Ok(json!({"impact": impact, "allowsSending": allows}))
        }
        "team.inviteEmail" => {
            Ok(directory::invite_email(&parse::<directory::EmailRequest>(request)?.text))
        }
        "team.inviteOutcome" => Ok(directory::invite_outcome(
            &parse::<directory::InviteOutcomeRequest>(request)?.result,
        )),
        "team.inviteAnswer" => {
            let r: directory::AnswerRequest = parse(request)?;
            Ok(directory::invite_answer(r.sent.as_deref(), r.by_person, &r.team))
        }
        _ => Err(OpError::Unknown),
    }
}

//! `cmux-cloud-start-core::moves` over the JSON channel (ops `cloud_move_*`): Move to Cloud, Bring
//! Back Local and a chat start's machine steps. The app runs the cmux-tui CLIs and git, reads its
//! defaults and the disk, observes its main-actor state, and asks here what each means.

use cmux_cloud_start_core::moves::{
    autosize, cli, folder, ledger, pin, place, progress, seed, targets, wait,
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_move_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn to_value<T: serde::Serialize>(value: T) -> Result<Value, i32> {
    serde_json::to_value(value).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Account {
    #[serde(default)]
    account: Vec<Option<String>>,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // The CLIs: the arguments of a call, and what its output means.
        b"cloud_move_cli_invocation" => {
            let call: cli::Call = read(request)?;
            to_value(cli::invocation(&call))?
        }
        b"cloud_move_cli_read" => {
            #[derive(Deserialize)]
            struct Request {
                reading: cli::Reading,
                #[serde(flatten)]
                output: cli::Output,
            }
            let request: Request = read(request)?;
            cli::read(request.reading, &request.output)
        }
        // The working toast's second line while a move runs: its step, why it waits, about how long is left.
        b"cloud_move_progress" => {
            let facts: progress::Facts = read(request)?;
            to_value(progress::line(&facts))?
        }
        b"cloud_move_restarted_daemon" => {
            let answer: cli::Answer = read(request)?;
            json!({ "restarted": answer.may_have_restarted_daemon() })
        }
        b"cloud_move_legacy_update" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(flatten)]
                run: cli::ExecRun,
                #[serde(default)]
                commit: String,
            }
            let request: Request = read(request)?;
            json!({
                "answer": to_value(request.run.legacy_update_answer(&request.commit))?,
                "lastLine": request.run.last_line(),
                "failureDetail": request.run.failure_detail(),
            })
        }
        // The legacy update's pin: the bundled manifest's for `build`, else the CLI's answer.
        b"cloud_move_pin" => {
            #[derive(Default, Deserialize)]
            #[serde(default)]
            struct Request {
                manifest: Option<String>,
                answer: Option<String>,
                build: Option<String>,
            }
            let request: Request = read(request)?;
            match request.manifest.as_deref().and_then(pin::from_manifest) {
                Some(bundled) => {
                    let pin = match request.build.as_deref() {
                        Some(build) => pin::for_build(build, bundled),
                        None => Some(bundled),
                    };
                    json!({ "pin": to_value(pin)?, "bundled": true, "target": pin::TARGET })
                }
                None => {
                    json!({ "pin": to_value(request.answer.as_deref().and_then(pin::from_answer))?, "bundled": false, "target": pin::TARGET })
                }
            }
        }
        b"cloud_move_is_hex" => {
            #[derive(Deserialize)]
            struct Request {
                text: String,
                count: usize,
            }
            let request: Request = read(request)?;
            json!({ "hex": pin::is_hex(&request.text, request.count) })
        }
        // The folder a chat moves with: its working copy (found on this disk), else itself.
        b"cloud_move_folder" => {
            #[derive(Deserialize)]
            struct Request {
                chat: String,
            }
            let request: Request = read(request)?;
            let found = folder::move_folder(&request.chat, |folder| {
                std::path::Path::new(folder).join(".git").exists()
            });
            json!({ "folder": to_value(found)? })
        }
        b"cloud_move_folder_remote" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                root: String,
                #[serde(default)]
                subpath: String,
                work_root: String,
            }
            let request: Request = read(request)?;
            to_value(folder::remote(&request.root, &request.subpath, &request.work_root))?
        }
        b"cloud_move_new_workspace_route" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                unavailable_reason: Option<String>,
                signed_in: bool,
                has_window: bool,
            }
            let request: Request = read(request)?;
            to_value(folder::route(
                request.unavailable_reason.as_deref(),
                request.signed_in,
                request.has_window,
            ))?
        }
        b"cloud_move_new_workspace_plan" => {
            let toggle: folder::Toggle = read(request)?;
            match folder::plan(&toggle) {
                Some(source) => json!({ "cloud": true, "source": source }),
                None => json!({ "cloud": false }),
            }
        }
        b"cloud_move_copy_step" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(flatten)]
                answer: folder::CopyAnswer,
                last: bool,
            }
            let request: Request = read(request)?;
            to_value(folder::copy_step(&request.answer, request.last))?
        }
        b"cloud_move_new_workspace_machine" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                named: Option<String>,
                by_person: bool,
                #[serde(default)]
                focused: Option<String>,
            }
            let request: Request = read(request)?;
            to_value(folder::new_workspace_machine(
                request.named.as_deref(),
                request.by_person,
                request.focused.as_deref(),
            ))?
        }
        // The ledgers, as stored in the app's defaults.
        b"cloud_move_retries" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                stored: Option<String>,
                #[serde(default)]
                tab: String,
                /// Set (or clear, with none) `tab`'s retry; else read the ledger.
                #[serde(default)]
                set: bool,
                #[serde(default)]
                retry: Option<ledger::Retry>,
            }
            let request: Request = read(request)?;
            if request.set {
                match ledger::set_retry(request.stored.as_deref(), &request.tab, request.retry) {
                    Some(value) => json!({ "changed": true, "stored": value }),
                    None => json!({ "changed": false }),
                }
            } else {
                json!({ "retries": to_value(ledger::retries(request.stored.as_deref()))? })
            }
        }
        b"cloud_move_moved_chats" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(flatten)]
                ledgers: ledger::MovedChats,
                action: String,
                #[serde(default)]
                host: String,
                #[serde(default)]
                session: String,
                #[serde(default)]
                remote_chat: Option<String>,
                #[serde(default)]
                harness: Option<String>,
                #[serde(default)]
                entry: Option<ledger::Moved>,
            }
            let request: Request = read(request)?;
            let ledgers = &request.ledgers;
            match (request.action.as_str(), request.entry) {
                ("entry", _) => {
                    json!({ "entry": to_value(ledgers.entry(&request.host, &request.session))? })
                }
                ("all", _) => json!({ "entries": to_value(ledgers.all())? }),
                ("record", Some(entry)) => json!({ "write": to_value(ledgers.record(entry))? }),
                ("copied", Some(entry)) => json!({ "write": to_value(ledgers.copied(entry))? }),
                ("started", _) => {
                    let (started, write) = ledgers.started(
                        &request.host,
                        &request.session,
                        request.remote_chat.as_deref(),
                        request.harness.as_deref(),
                    );
                    json!({ "started": started, "write": to_value(write)? })
                }
                ("forget", _) => {
                    json!({ "write": to_value(ledgers.forget(&request.host, &request.session))? })
                }
                _ => return Err(ERR_INVALID),
            }
        }
        b"cloud_move_grants" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                stored: Option<String>,
                action: String,
                #[serde(default, rename = "userID")]
                user_id: Option<String>,
                #[serde(default, rename = "teamID")]
                team_id: Option<String>,
                #[serde(default)]
                cloud_origin: String,
                #[serde(default)]
                folder: String,
                #[serde(default)]
                always: bool,
                #[serde(default)]
                grants: Vec<ledger::Grant>,
            }
            let request: Request = read(request)?;
            let scope = ledger::Scope::new(
                request.user_id.as_deref(),
                request.team_id.as_deref(),
                &request.cloud_origin,
            );
            let stored = request.stored.as_deref();
            match request.action.as_str() {
                "scope" => json!({ "valid": scope.is_some() }),
                "contains" => {
                    json!({ "granted": ledger::granted(stored, scope.as_ref(), &request.folder) })
                }
                "remember" => {
                    json!({ "stored": ledger::remember(stored, scope.as_ref(), &request.folder, request.always) })
                }
                "list" => json!({ "grants": to_value(ledger::grants(stored))? }),
                "store" => json!({ "stored": ledger::store_grants(request.grants) }),
                _ => return Err(ERR_INVALID),
            }
        }
        // A seed's progress lines.
        b"cloud_move_seed_read" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                /// The reader's memory; none parses the line alone.
                #[serde(default)]
                reader: Option<seed::Reader>,
                line: String,
                #[serde(default)]
                now_ms: f64,
            }
            let request: Request = read(request)?;
            match request.reader {
                Some(mut reader) => {
                    let progress = reader.read(&request.line, request.now_ms);
                    json!({ "progress": to_value(progress)?, "reader": to_value(reader)? })
                }
                None => json!({ "progress": to_value(seed::parse(&request.line))? }),
            }
        }
        // The chat's machine pick.
        b"cloud_move_task_kind" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                text: Option<String>,
            }
            let request: Request = read(request)?;
            json!({ "kind": to_value(autosize::task_kind(request.text.as_deref()))? })
        }
        b"cloud_move_autosize_body" => {
            let request: autosize::Autosize = read(request)?;
            json!({ "body": request.body() })
        }
        b"cloud_move_work_pick_remote" => {
            #[derive(Deserialize)]
            struct Request {
                upstream: String,
            }
            let request: Request = read(request)?;
            json!({ "name": autosize::remote_name(&request.upstream) })
        }
        b"cloud_move_work_pick" => {
            let facts: autosize::Facts = read(request)?;
            to_value(autosize::work_pick(&facts))?
        }
        // The waits' rules.
        b"cloud_move_deadlines" => to_value(wait::DEADLINES)?,
        b"cloud_move_link_look" => {
            let look: wait::LinkLook = read(request)?;
            let (done, cleared) = wait::link_look(look);
            json!({ "done": done, "cleared": cleared })
        }
        b"cloud_move_start_redial" => {
            let look: wait::RedialLook = read(request)?;
            json!({ "redial": to_value(wait::start_redial(look))? })
        }
        b"cloud_move_rereads_record" => {
            let look: wait::RecordLook = read(request)?;
            json!({ "rereads": wait::rereads_record(look) })
        }
        b"cloud_move_relinked" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                before: Option<String>,
                #[serde(default)]
                now: Option<String>,
                #[serde(default)]
                refused_counts: bool,
            }
            let request: Request = read(request)?;
            json!({ "relinked": wait::relinked(request.before.as_deref(), request.now.as_deref(), request.refused_counts) })
        }
        b"cloud_move_link_dropped" => {
            let failure: wait::StartFailure = read(request)?;
            json!({ "dropped": wait::link_dropped(&failure) })
        }
        b"cloud_move_outdated_refusal" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                ok: bool,
                #[serde(default)]
                error_code: Option<String>,
                #[serde(default)]
                side: Option<String>,
            }
            let request: Request = read(request)?;
            json!({ "updates": wait::updates_before_copying_again(request.ok, request.error_code.as_deref(), request.side.as_deref()) })
        }
        b"cloud_move_runs" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                kept: Vec<wait::KeptRun>,
                keeping: usize,
            }
            let request: Request = read(request)?;
            json!({ "drop": wait::runs_to_drop(&request.kept, request.keeping) })
        }
        b"cloud_move_run_reusable" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                age_ms: u64,
            }
            let request: Request = read(request)?;
            json!({ "reusable": wait::run_reusable(request.age_ms) })
        }
        // Move to…: where a started chat can go.
        b"cloud_move_targets" => {
            let chat: targets::Chat = read(request)?;
            json!({ "targets": targets::targets(&chat) })
        }
        // Move to… an SSH machine: the `acpmux session move` call, then what its answer means.
        b"cloud_move_ssh_move" => {
            let request: targets::SshMove = read(request)?;
            match targets::ssh_move(&request) {
                Ok(call) => json!({ "call": to_value(call)? }),
                Err(refusal) => json!({ "refusal": refusal }),
            }
        }
        b"cloud_move_ssh_move_outcome" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                stdout: String,
                #[serde(default)]
                stderr: String,
                status: i32,
            }
            let request: Request = read(request)?;
            to_value(targets::ssh_move_result(&request.stdout, &request.stderr, request.status))?
        }
        // What the move means for the tab: the session it opens, the one question, or the failure.
        b"cloud_move_ssh_move_run" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                stdout: String,
                #[serde(default)]
                stderr: String,
                status: i32,
                #[serde(default)]
                moved: String,
                destination: String,
                #[serde(default)]
                dry_run: bool,
            }
            let request: Request = read(request)?;
            let result = targets::ssh_move_result(&request.stdout, &request.stderr, request.status);
            to_value(targets::ssh_move_run(
                &request.moved,
                &request.destination,
                request.dry_run,
                &result,
            ))?
        }
        b"cloud_move_list_current" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                loaded_ago_ms: Option<u64>,
                #[serde(default)]
                loaded_for: Option<Vec<Option<String>>>,
                #[serde(default)]
                account: Vec<Option<String>>,
                within_ms: u64,
            }
            let request: Request = read(request)?;
            let current = wait::list_current(
                request.loaded_ago_ms,
                request.loaded_for.as_deref(),
                &request.account,
                request.within_ms,
            );
            json!({ "current": current })
        }
        // The start's own words.
        b"cloud_move_starts_as_person" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                by_person: bool,
                delegated: bool,
            }
            let request: Request = read(request)?;
            json!({ "person": wait::starts_as_person(request.by_person, request.delegated) })
        }
        b"cloud_move_copies_through_store" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(flatten)]
                account: Account,
                production_auth: bool,
            }
            let request: Request = read(request)?;
            json!({ "store": wait::copies_through_store(&request.account.account, request.production_auth) })
        }
        b"cloud_move_shell_quoted" => {
            #[derive(Deserialize)]
            struct Request {
                text: String,
            }
            let request: Request = read(request)?;
            json!({ "word": wait::shell_quoted(&request.text) })
        }
        b"cloud_move_plan_request" => {
            let facts: wait::PlanFacts = read(request)?;
            json!({ "request": wait::plan_request(&facts) })
        }
        // Where a chat runs and moving it (`moves/place.rs`): the move's state machine and its
        // view, the Auto rule, Evacuate's plan and the own-VM pick.
        b"cloud_move_place_reduce" => {
            #[derive(Deserialize)]
            struct Request {
                flow: Option<place::Flow>,
                event: place::Event,
            }
            let request: Request = read(request)?;
            let (flow, next) = place::reduce(request.flow, request.event);
            json!({ "flow": flow, "next": next })
        }
        b"cloud_move_place_view" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                flow: place::Flow,
                now_ms: u64,
            }
            let request: Request = read(request)?;
            to_value(place::view(&request.flow, request.now_ms))?
        }
        b"cloud_move_place_auto" => {
            #[derive(Deserialize)]
            struct Request {
                mode: place::Mode,
                chat: place::ChatState,
                signals: place::Signals,
            }
            let request: Request = read(request)?;
            to_value(place::auto(request.mode, &request.chat, &request.signals))?
        }
        b"cloud_move_place_evacuate" => {
            #[derive(Deserialize)]
            struct Request {
                chats: Vec<place::EvacuateChat>,
                #[serde(default)]
                selected: Option<Vec<String>>,
                /// `toCloud` (Evacuate, the default) or `toLocal` (Bring Back All).
                #[serde(default)]
                direction: Option<place::Direction>,
            }
            let request: Request = read(request)?;
            to_value(place::evacuate_toward(
                &request.chats,
                request.selected.as_deref(),
                request.direction.unwrap_or(place::Direction::ToCloud),
            ))?
        }
        b"cloud_move_place_vm_failure" => {
            let error: place::VmError = read(request)?;
            to_value(serde_json::json!({ "cause": place::vm_failure_cause(&error) }))?
        }
        b"cloud_move_place_own_machine" => {
            #[derive(Deserialize)]
            struct Request {
                session: String,
                #[serde(default)]
                before: Option<String>,
                #[serde(default)]
                machines: Vec<place::Machine>,
            }
            let request: Request = read(request)?;
            to_value(place::own_machine(
                &request.session,
                request.before.as_deref(),
                &request.machines,
            ))?
        }
        b"cloud_move_place_steps" => {
            let steps: Vec<_> = place::Step::ALL
                .iter()
                .map(|step| json!({ "step": step.name(), "cancellable": step.cancellable(), "landed": step.landed(), "agentMovePhases": step.agent_move_phases() }))
                .collect();
            json!({ "steps": steps, "budgetMs": place::BUDGET_MS })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

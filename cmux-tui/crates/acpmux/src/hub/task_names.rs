//! Part of `Hub`; see `hub/mod.rs`. A session's name follows its task (Leo asked that session
//! names follow their task, 2026-11-20): when its goal is set (`goal_tools.rs`, the `goal_set`
//! tool) with a new objective, the title model (`titles.rs`) gives the objective a title of 2 to
//! 5 words, which becomes the session's title (`title_source` [`TASK`]) and, as a slug
//! (`fix-sidebar-spinner`), its name, through the one rename path (`Hub::rename_as`), so its old
//! name still finds it (`former_names.rs`). A goal set again with the same objective renames only
//! a session whose name is no task's (`ask-0123abcd45`, `claude-3`, `coordination`). Nothing is
//! renamed when the title answer is empty or fails, when the goal or the name changed while it
//! was asked for (a rename by hand after the task change wins), and never a registered chat (its
//! name is its address, `register.rs`) or a sub-session (`PARENT/SHORT`, its starter's name).
//! Only goals rename: a prompt never does.

use super::*;

/// `SessionMeta.title_source` of a title its task gave it.
pub(crate) const TASK: &str = "task";
/// The longest slug a task names a session with, in characters.
const MAX_SLUG: usize = 40;
const MAX_WORDS: usize = 5;
const SYSTEM: &str = "You name tasks. Reply with a title of 2 to 5 words for the task below and nothing else: no quotes, no trailing punctuation.";

/// Who names a session in a rename (`Hub::rename_as`).
#[derive(Clone, Copy, Debug)]
pub(crate) enum Naming<'a> {
    /// A person or an agent (`acpmux rename`): titled by the name in words, `NAMED`.
    Hand,
    /// Its task, with the title the name was made from: `TASK`.
    Task(&'a str),
    /// `acpmux register`: the name is an address; the title stays.
    Address,
}

/// A name in words, for its title: the last `/` segment with `-` and `_` read as spaces and its
/// first letter upper case (`session-name-aliases` reads "Session name aliases"). A name with
/// spaces stays as given. None for an empty name.
pub(crate) fn name_in_words(name: &str) -> Option<String> {
    let name = name.trim();
    if name.contains(' ') {
        return Some(name.to_owned());
    }
    let bare = name.rsplit('/').next().unwrap_or(name);
    let words: Vec<&str> = bare.split(['-', '_']).filter(|w| !w.is_empty()).collect();
    let text = words.join(" ");
    let mut chars = text.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().chain(chars).collect())
}

/// The session name a task's title gives: lowercase ASCII words joined by `-`, at most
/// [`MAX_SLUG`] characters (whole words), None when no ASCII letter or digit is left.
pub(crate) fn task_slug(title: &str) -> Option<String> {
    let mut slug = String::new();
    let words = title
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_ascii_lowercase);
    for word in words {
        let extra = if slug.is_empty() { word.len() } else { word.len() + 1 };
        if slug.len() + extra > MAX_SLUG {
            if slug.is_empty() {
                slug = word.chars().take(MAX_SLUG).collect();
            }
            break;
        }
        if !slug.is_empty() {
            slug.push('-');
        }
        slug.push_str(&word);
    }
    (!slug.is_empty()).then_some(slug)
}

/// Whether `name` names a task, not a default or a counter: the daemon's and the app's
/// fallbacks (`ask-<hex>`, `claude-3`, `claude-desktop-<hex>`, `coordination`) and any name that
/// reads as an id (`session_name::opaque_reason`) do not.
pub(crate) fn is_task_name(name: &str) -> bool {
    let bare = name.rsplit('/').next().unwrap_or(name);
    !(bare.is_empty()
        || crate::session_name::opaque_reason(bare).is_some()
        || matches!(
            bare,
            "coordination" | "coordinator" | "chat" | "session" | "untitled" | "new-chat"
        )
        || bare.starts_with("ask-")
        || bare.starts_with("claude-desktop-"))
}

/// A task's title, cleaned as a chat title is (`titles::clean`) and cut to [`MAX_WORDS`].
fn task_title_of(answer: &str) -> Option<String> {
    let title = super::titles::clean(answer)?;
    Some(title.split_whitespace().take(MAX_WORDS).collect::<Vec<_>>().join(" "))
}

/// What a goal set left to name: the goal (`objective`, `created_at`) and the name it was set
/// on, compared again when the title comes back.
#[derive(Clone, Debug)]
pub(crate) struct TaskNaming {
    pub(crate) objective: String,
    pub(crate) goal_at: Option<Value>,
    pub(crate) name: String,
}

impl Hub {
    /// `goal_set`, then the session named after the goal's objective when it changed (or its
    /// name is no task's): the title is asked for in the background.
    pub(crate) fn goal_set_named(
        self: &Arc<Self>,
        session: &Arc<Session>,
        request: &crate::generic_goal::GoalRequest,
    ) -> Result<Value, RpcError> {
        let before = session.read_meta(|m| m.goal.as_ref().map(|g| g.objective.clone()));
        let value = self.goal_set(session, request)?;
        if let Some(naming) = self.task_naming(session, before.as_deref()) {
            let (hub, session) = (Arc::clone(self), Arc::clone(session));
            self.scope.spawn_until_cancelled("task-name", async move {
                let harness = session.read_meta(|m| m.harness.clone());
                let title = hub.task_title(&harness, &naming.objective).await;
                hub.name_after_task(&session, &naming, title).await;
            });
        }
        Ok(value)
    }

    /// What a goal just set should name `session` after, or None when it should not rename:
    /// the objective is the one it had (`before`) and its name is already a task's, or the
    /// session's name is not its own to change.
    pub(crate) fn task_naming(
        &self,
        session: &Session,
        before: Option<&str>,
    ) -> Option<TaskNaming> {
        if super::register::is_registered(session) {
            return None;
        }
        session.read_meta(|m| {
            let goal = m.goal.as_ref()?;
            if m.throwaway || m.subsession.is_some() || m.name.contains('/') {
                return None;
            }
            let changed = before.is_none_or(|b| b.trim() != goal.objective.trim());
            if !changed && is_task_name(&m.name) {
                return None;
            }
            Some(TaskNaming {
                objective: goal.objective.clone(),
                goal_at: goal.created_at.clone(),
                name: m.name.clone(),
            })
        })
    }

    /// The title model's 2-5 word title for `objective` (`titles.rs`'s command or completion),
    /// None when titles are off or the answer is empty or fails.
    async fn task_title(self: &Arc<Self>, harness: &str, objective: &str) -> Option<String> {
        let (custom, model, enabled) = {
            let cfg = self.config.read().await;
            let custom = cfg.titles.command.as_ref().is_some_and(|c| !c.is_empty())
                || std::env::var("ACPMUX_TITLE_COMMAND").is_ok_and(|c| !c.trim().is_empty());
            (custom, cfg.titles.model.clone(), cfg.titles.generate != Some(false))
        };
        if !enabled {
            return None;
        }
        let request = format!("{SYSTEM}\n\nThe task:\n{objective}\n");
        if custom {
            let command = self.title_command(harness).await?;
            let answer = super::titles::run(command, &request).await?;
            return task_title_of(&answer);
        }
        let mut params = json!({"prompt": request, "harness": harness, "maxTokens": 16});
        if let Some(model) = model
            && let Some(params) = params.as_object_mut()
        {
            params.insert("model".to_owned(), json!(model));
        }
        let result = self.complete(crate::server::Origin::Local, &params).await.ok()?;
        task_title_of(result.get("text").and_then(Value::as_str)?)
    }

    /// Names `session` after its task's `title`, when the goal and the name are still those of
    /// `naming` (a rename or a new goal since wins). The name is the title's slug, made unique
    /// with `-2`, `-3`; the old name stays a former name. Returns whether it named it.
    pub(crate) async fn name_after_task(
        &self,
        session: &Arc<Session>,
        naming: &TaskNaming,
        title: Option<String>,
    ) -> bool {
        let Some(title) = title.filter(|t| !t.trim().is_empty()) else { return false };
        let Some(slug) = task_slug(&title) else { return false };
        let current = session.read_meta(|m| {
            m.name == naming.name
                && m.goal.as_ref().is_some_and(|g| {
                    g.objective == naming.objective && g.created_at == naming.goal_at
                })
        });
        if !current || super::register::is_registered(session) {
            return false;
        }
        let name = self.free_task_name(&slug, &session.id);
        if name == naming.name {
            // Its name is already the task's: only the title changes.
            {
                let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                m.title = Some(title.clone());
                m.title_source = Some(TASK.to_owned());
                m.title_prompt = None;
            }
            self.append(session, "mux", "titled", json!({"title": title}));
            self.save_meta(session);
            return true;
        }
        match self.rename_as(session, name, Naming::Task(&title)).await {
            Ok(()) => true,
            Err(e) => {
                tracing::info!(session = %session.id, "a task name was not given: {}", e.message);
                false
            }
        }
    }

    /// `slug`, or `slug-2`, `slug-3`, ... : the first that no other session has as its name.
    fn free_task_name(&self, slug: &str, own: &str) -> String {
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        let taken =
            |name: &str| sessions.values().any(|s| s.id != own && s.read_meta(|m| m.name == name));
        if !taken(slug) {
            return slug.to_owned();
        }
        (2..)
            .map(|n| format!("{slug}-{n}"))
            .find(|name| !taken(name))
            .unwrap_or_else(|| slug.to_owned())
    }
}

#[cfg(test)]
#[path = "task_names_tests.rs"]
mod tests;

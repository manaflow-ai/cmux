use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

type Hook = Arc<dyn Fn() + Send + Sync>;

static HOOKS: Mutex<Option<HashMap<String, Hook>>> = Mutex::new(None);

pub(crate) fn set(terminal_id: &str, hook: Option<Hook>) {
    let mut hooks = HOOKS.lock().unwrap_or_else(PoisonError::into_inner);
    let hooks = hooks.get_or_insert_with(HashMap::new);
    match hook {
        Some(hook) => hooks.insert(terminal_id.to_string(), hook),
        None => hooks.remove(terminal_id),
    };
}

pub(super) fn run(terminal_id: &str) {
    let hook = HOOKS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .as_ref()
        .and_then(|hooks| hooks.get(terminal_id).cloned());
    if let Some(hook) = hook {
        hook();
    }
}

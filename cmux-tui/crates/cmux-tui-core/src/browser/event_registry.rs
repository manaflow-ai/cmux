//! Durable event effects use the existing command worker. Only the originating
//! event lane pauses, preserving page/mark ordering while other lanes progress.

use super::event_lanes::ResumeEventLane;
use super::*;
use crate::panic_free::RecoverPoison;
use anyhow::Context;

pub(super) enum RegistryWork {
    ClearAttention(String),
    AdoptTarget { created: TargetCreated, opener: BrowserSession },
    SurfaceExited,
    RestartProvider,
}

pub(super) struct DeferredRegistryWork {
    work: RegistryWork,
    _resume: ResumeEventLane,
}

impl BrowserSurface {
    pub(super) fn defer_registry_work(
        &self,
        route: &Weak<SurfaceRoute>,
        work: RegistryWork,
    ) -> anyhow::Result<()> {
        let exiting = matches!(&work, RegistryWork::SurfaceExited);
        if self.is_dead() && !exiting {
            anyhow::bail!("browser surface is closed");
        }
        let tx = self.command_sender()?;
        let route = route.upgrade().context("browser event route is closed")?;
        let resume = route.pause();
        let mut order = self.command_order.lock().recover_poison();
        // Old/new provider routes can overlap. Bound even pathological lease
        // churn; overflow ends this surface, using a separately reserved exit
        // so ordinary input or registry work can never drop its durable close.
        let overflow = !exiting && order.registry_work.len() >= BROWSER_COMMAND_QUEUE_CAPACITY;
        let work = if overflow { RegistryWork::SurfaceExited } else { work };
        let deferred = DeferredRegistryWork { work, _resume: resume };
        let command = order.sequence(BrowserCommand::EventRegistry(Box::new(deferred)));
        if exiting || overflow {
            order.registry_exit = Some(command);
        } else {
            order.registry_work.push_back(command);
        }
        let wake = order.sequence(BrowserCommand::WakeLatest);
        match tx.try_send(wake) {
            Ok(()) | Err(TrySendError::Full(_)) => {}
            Err(TrySendError::Disconnected(_)) => {
                if exiting || overflow {
                    order.registry_exit.take();
                } else {
                    order.registry_work.pop_back();
                }
                anyhow::bail!("browser command worker is closed")
            }
        }
        drop(order);
        if overflow {
            self.kill();
            anyhow::bail!("browser registry event queue overflow; surface closed");
        }
        Ok(())
    }
}

pub(super) fn run_registry_work(
    browser: &BrowserSurface,
    deferred: DeferredRegistryWork,
    mux: &Weak<Mux>,
    id: SurfaceId,
) {
    // Keep the resume token until the durable effect finishes, including
    // early returns and unwind. Later events cannot change this page first.
    let DeferredRegistryWork { work, _resume } = deferred;
    match work {
        RegistryWork::AdoptTarget { created, opener } => {
            let current = browser.session.lock().recover_poison().clone();
            let valid = !browser.is_dead()
                && current.as_ref().is_some_and(|current| {
                    current.session_id == opener.session_id
                        && Arc::ptr_eq(&current.runtime, &opener.runtime)
                });
            let adopted = if valid {
                mux.upgrade().map(|mux| {
                    let result = mux.adopt_browser_target(
                        id,
                        created.target_id.clone(),
                        if created.url.is_empty() { "about:blank".into() } else { created.url },
                        opener.runtime.clone(),
                    );
                    if let Err(error) = &result {
                        mux.emit(MuxEvent::Status(format!(
                            "browser target adoption failed: {error}"
                        )));
                    }
                    result
                })
            } else {
                None
            };
            if !matches!(adopted, Some(Ok(true))) {
                let _ = opener.runtime.client.close_target_detached(&created.target_id);
            }
        }
        RegistryWork::ClearAttention(page) => {
            if !browser.is_dead()
                && let Some(mux) = mux.upgrade()
            {
                mux.clear_attention_after_navigation(&crate::Actor::Daemon, id, &page);
            }
        }
        RegistryWork::SurfaceExited => {
            if let Some(mux) = mux.upgrade() {
                mux.surface_exited(id);
            }
        }
        RegistryWork::RestartProvider => {
            let needs_restart =
                !browser.is_dead() && browser.session.lock().recover_poison().is_none();
            if needs_restart
                && let Some(mux) = mux.upgrade()
                && let Some(surface) = mux.surface(id)
            {
                mux.restart_provider_browser_surface(surface);
            }
        }
    }
}

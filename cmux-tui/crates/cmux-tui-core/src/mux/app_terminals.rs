//! Terminals an app brings: a byte-backend terminal is a tab-less session
//! on this session host until the client that made the gesture places it
//! (apps/terminal_ops.rs).

use std::sync::Arc;

use super::{Mux, insert_surface_checked};
use crate::SurfaceId;
use crate::surface::Surface;
use crate::terminal_backend::pty::BackendSide;

impl Mux {
    /// Creates the tab-less terminal surface of an app's byte-backend
    /// terminal at the daemon's default size; answers its surface id.
    pub(crate) fn spawn_backend_terminal(
        self: &Arc<Self>,
        side: BackendSide,
    ) -> anyhow::Result<SurfaceId> {
        let id = self.next_id();
        let opts = self.surface_options.lock().unwrap().clone();
        let cell_pixels = {
            let cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let cell_pixels = self.cell_pixel_creation_size();
            drop(cell_pixel_lifecycle);
            cell_pixels
        };
        let surface = Surface::spawn_backend(id, opts, Arc::downgrade(self), cell_pixels, side)?;
        let cell_pixel_lifecycle = match self.reconcile_surface_cell_pixels_for_publish(&surface) {
            Ok(lifecycle) => lifecycle,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        let insert_result =
            insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
        drop(cell_pixel_lifecycle);
        if let Err(error) = insert_result {
            surface.kill();
            return Err(error);
        }
        Ok(id)
    }
}

impl Mux {
    /// Removes a tab-less backend terminal surface and stops it (its killer
    /// closes the app's terminal). A surface that is gone is ignored.
    pub(crate) fn close_backend_terminal(&self, id: SurfaceId) {
        let surface = self.state.lock().unwrap().surfaces.remove(&id);
        if let Some(surface) = surface {
            surface.kill();
            self.emit(super::MuxEvent::SurfaceExited(surface.id));
        }
    }
}

#[cfg(test)]
#[path = "app_terminals_tests.rs"]
mod tests;

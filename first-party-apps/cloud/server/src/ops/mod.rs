//! Op dispatch (red-test stub: no op is served yet).

mod machine_projection;

pub use machine_projection::{Change, Projection, ProjectionEvent};

use crate::api::{CloudError, ControlPlane, Request, codes};
use serde_json::Value;

pub fn canonical_name(_op: &str) -> Option<&'static str> {
    None
}

pub fn op_names() -> impl Iterator<Item = &'static str> {
    std::iter::empty()
}

pub struct Server<C> {
    control_plane: C,
    projection: Projection,
}

impl<C: ControlPlane> Server<C> {
    pub fn new(control_plane: C) -> Self {
        Self { control_plane, projection: Projection::default() }
    }

    pub fn control_plane(&self) -> &C {
        &self.control_plane
    }

    pub fn control_plane_mut(&mut self) -> &mut C {
        &mut self.control_plane
    }

    pub fn projection(&self) -> &Projection {
        &self.projection
    }

    pub fn take_events(&mut self) -> Vec<ProjectionEvent> {
        self.projection.take_events()
    }

    pub fn handle(&mut self, request: &Request) -> Result<Value, CloudError> {
        Err(CloudError::new(codes::UNKNOWN_OP, format!("{} is not served yet", request.op)))
    }
}

//! One value per [`Lane`], looked up by lane with a `match` instead of an
//! array index, so a lookup cannot go out of bounds.

use cmux_remote_protocol::Lane;

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct PerLane<T> {
    pub(crate) interactive: T,
    pub(crate) control: T,
    pub(crate) bulk: T,
    pub(crate) tunnel: T,
}

impl<T> PerLane<T> {
    pub(crate) fn from_fn(mut make: impl FnMut(Lane) -> T) -> Self {
        Self {
            interactive: make(Lane::Interactive),
            control: make(Lane::Control),
            bulk: make(Lane::Bulk),
            tunnel: make(Lane::Tunnel),
        }
    }

    pub(crate) fn map<U>(self, mut f: impl FnMut(T) -> U) -> PerLane<U> {
        PerLane {
            interactive: f(self.interactive),
            control: f(self.control),
            bulk: f(self.bulk),
            tunnel: f(self.tunnel),
        }
    }

    pub(crate) fn get(&self, lane: Lane) -> &T {
        match lane {
            Lane::Interactive => &self.interactive,
            Lane::Control => &self.control,
            Lane::Bulk => &self.bulk,
            Lane::Tunnel => &self.tunnel,
        }
    }

    pub(crate) fn get_mut(&mut self, lane: Lane) -> &mut T {
        match lane {
            Lane::Interactive => &mut self.interactive,
            Lane::Control => &mut self.control,
            Lane::Bulk => &mut self.bulk,
            Lane::Tunnel => &mut self.tunnel,
        }
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = &T> {
        [&self.interactive, &self.control, &self.bulk, &self.tunnel].into_iter()
    }
}

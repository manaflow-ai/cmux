use super::Controller;

#[derive(Debug)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct NoControl;

impl Controller for NoControl {
    fn window(&self) -> usize {
        usize::MAX
    }
}

//! libtailscale's C API (tailscale.h at the pinned commit in build.rs).

use std::os::raw::{c_char, c_int};

pub type Tailscale = c_int;
pub type TailscaleConn = c_int;
pub type TailscaleListener = c_int;

unsafe extern "C" {
    pub fn tailscale_new() -> Tailscale;
    pub fn tailscale_start(sd: Tailscale) -> c_int;
    pub fn tailscale_close(sd: Tailscale) -> c_int;
    pub fn tailscale_set_dir(sd: Tailscale, dir: *const c_char) -> c_int;
    pub fn tailscale_set_hostname(sd: Tailscale, hostname: *const c_char) -> c_int;
    pub fn tailscale_set_authkey(sd: Tailscale, authkey: *const c_char) -> c_int;
    pub fn tailscale_set_control_url(sd: Tailscale, control_url: *const c_char) -> c_int;
    pub fn tailscale_set_ephemeral(sd: Tailscale, ephemeral: c_int) -> c_int;
    pub fn tailscale_set_logfd(sd: Tailscale, fd: c_int) -> c_int;
    pub fn tailscale_getips(sd: Tailscale, buf: *mut c_char, buflen: usize) -> c_int;
    pub fn tailscale_dial(
        sd: Tailscale,
        network: *const c_char,
        addr: *const c_char,
        conn_out: *mut TailscaleConn,
    ) -> c_int;
    pub fn tailscale_listen(
        sd: Tailscale,
        network: *const c_char,
        addr: *const c_char,
        listener_out: *mut TailscaleListener,
    ) -> c_int;
    pub fn tailscale_getremoteaddr(
        l: TailscaleListener,
        conn: TailscaleConn,
        buf: *mut c_char,
        buflen: usize,
    ) -> c_int;
    pub fn tailscale_accept(listener: TailscaleListener, conn_out: *mut TailscaleConn) -> c_int;
    pub fn tailscale_loopback(
        sd: Tailscale,
        addr_out: *mut c_char,
        addrlen: usize,
        proxy_cred_out: *mut c_char,
        local_api_cred_out: *mut c_char,
    ) -> c_int;
    pub fn tailscale_status_json(sd: Tailscale, json_out: *mut *mut c_char) -> c_int;
    pub fn tailscale_errmsg(sd: Tailscale, buf: *mut c_char, buflen: usize) -> c_int;
}

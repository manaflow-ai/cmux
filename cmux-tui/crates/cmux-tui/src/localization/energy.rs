//! `energy` strings of the CLI catalog (English and Japanese): `cmux energy`
//! (cli/energy.rs).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct EnergyMessages {
    pub usage: &'static str,
    pub unknown_verb: &'static str,
    pub unexpected_argument: &'static str,
    /// The app's saver, on: `{reason}` is one of the `reason_*` strings.
    pub app_on: &'static str,
    pub app_off: &'static str,
    pub app_held_off: &'static str,
    pub app_unreachable: &'static str,
    pub daemon_on_app: &'static str,
    pub daemon_on_own: &'static str,
    pub daemon_off_app: &'static str,
    pub daemon_off_own: &'static str,
    pub daemon_unreachable: &'static str,
    pub reason_low_power_mode: &'static str,
    pub reason_battery: &'static str,
    pub reason_thermal: &'static str,
    pub reason_setting: &'static str,
}

pub(super) const ENGLISH: EnergyMessages = EnergyMessages {
    usage: "usage: cmux energy [status|off|on|auto] [--json]\n\nEnergy Saver: cmux slows its background and ambient work on battery, in Low\nPower Mode, or when its energy.saver setting asks for it.\n\n  cmux energy status   Whether Energy Saver is on, why, and what the daemon\n                       follows (the default verb).\n  cmux energy off      Turn Energy Saver off for now (until the Mac is plugged\n                       in or the energy.saver setting changes).\n  cmux energy on       End \"off for now\": Energy Saver follows its setting again.\n  cmux energy auto     The same as on.\n\nTo change when Energy Saver turns on, set energy.saver (auto, onBattery,\nalways, off) with cmux settings.\n",
    unknown_verb: "unknown energy verb \"{verb}\"; use status, off, on or auto",
    unexpected_argument: "energy {verb}: unexpected argument \"{value}\"",
    app_on: "Energy Saver: on ({reason})",
    app_off: "Energy Saver: off",
    app_held_off: "Energy Saver: off for now (cmux energy on ends this)",
    app_unreachable: "Energy Saver: the cmux app does not answer",
    daemon_on_app: "Daemon: on, as the app set it",
    daemon_on_own: "Daemon: on, from its own reading",
    daemon_off_app: "Daemon: off, as the app set it",
    daemon_off_own: "Daemon: off, from its own reading",
    daemon_unreachable: "Daemon: no answer ({error})",
    reason_low_power_mode: "Low Power Mode",
    reason_battery: "battery low",
    reason_thermal: "on battery and hot",
    reason_setting: "setting",
};

pub(super) const JAPANESE: EnergyMessages = EnergyMessages {
    usage: "使い方: cmux energy [status|off|on|auto] [--json]\n\n省エネモード: バッテリー駆動時、低電力モード時、または energy.saver 設定で\n指定したときに、cmux はバックグラウンドと常時表示の処理を減らします。\n\n  cmux energy status   省エネモードがオンかどうか、その理由、デーモンが従う\n                       状態を表示します (既定の動詞)。\n  cmux energy off      省エネモードを一時的にオフにします (電源に接続するか\n                       energy.saver 設定を変えるまで)。\n  cmux energy on       一時的なオフを終了し、設定に従う状態に戻します。\n  cmux energy auto     on と同じです。\n\n省エネモードがオンになる条件は、cmux settings で energy.saver (auto,\nonBattery, always, off) を設定して変更します。\n",
    unknown_verb: "不明な energy の動詞 \"{verb}\" です。status、off、on、auto のいずれかを指定してください",
    unexpected_argument: "energy {verb}: 予期しない引数 \"{value}\" です",
    app_on: "省エネモード: オン ({reason})",
    app_off: "省エネモード: オフ",
    app_held_off: "省エネモード: 一時的にオフ (cmux energy on で終了)",
    app_unreachable: "省エネモード: cmux アプリが応答しません",
    daemon_on_app: "デーモン: オン (アプリの設定)",
    daemon_on_own: "デーモン: オン (デーモン自身の読み取り)",
    daemon_off_app: "デーモン: オフ (アプリの設定)",
    daemon_off_own: "デーモン: オフ (デーモン自身の読み取り)",
    daemon_unreachable: "デーモン: 応答なし ({error})",
    reason_low_power_mode: "低電力モード",
    reason_battery: "バッテリー残量が少ない",
    reason_thermal: "バッテリー駆動中で高温",
    reason_setting: "設定",
};

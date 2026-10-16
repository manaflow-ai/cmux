// Passkey scenarios for the cmux test RP. Shared by index.html (top level)
// and frame.html (cross-origin iframe). Bug ids (K8, K11, ...) refer to the
// "Known bugs: do not repeat" table in plans/cmux-next/passkeys.md.
(() => {
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const rand = (n) => crypto.getRandomValues(new Uint8Array(n));
  const b64u = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const same = (a, b) => {
    const x = new Uint8Array(a), y = new Uint8Array(b);
    return x.length === y.length && x.every((v, i) => v === y[i]);
  };
  const errName = (e) => (e && e.name) || String(e);

  function clientData(cred) {
    return JSON.parse(dec.decode(cred.response.clientDataJSON));
  }
  // Flags byte of authenticatorData (after the 32-byte rpIdHash).
  function flags(authData) {
    const f = new Uint8Array(authData)[32];
    return { up: !!(f & 1), uv: !!(f & 4), be: !!(f & 8), bs: !!(f & 16), at: !!(f & 64), ed: !!(f & 128) };
  }
  function checkClientData(cred, type, challenge, extra = {}) {
    const cd = clientData(cred);
    const problems = [];
    if (cd.type !== type) problems.push(`type ${cd.type}`);
    if (cd.origin !== location.origin) problems.push(`origin ${cd.origin}`);
    if (cd.challenge !== b64u(challenge)) problems.push("challenge not echoed");
    if (extra.crossOrigin !== undefined && !!cd.crossOrigin !== extra.crossOrigin) problems.push(`crossOrigin ${cd.crossOrigin}`);
    if (extra.topOrigin !== undefined && cd.topOrigin !== extra.topOrigin) problems.push(`topOrigin ${cd.topOrigin}`);
    return { cd, problems };
  }

  const rpId = location.hostname;
  function creationOptions(over = {}) {
    const userId = over.userId || rand(16);
    return {
      challenge: over.challenge || rand(32),
      rp: { id: over.rpId || rpId, name: "cmux test RP" },
      user: { id: userId, name: "agent@cmux.test", displayName: "cmux test" },
      pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
      authenticatorSelection: over.authenticatorSelection || { residentKey: "required", userVerification: "required" },
      extensions: over.extensions,
      attestation: over.attestation,
      excludeCredentials: over.excludeCredentials,
      timeout: over.timeout || 20000,
    };
  }
  async function create(over = {}) {
    const options = creationOptions(over);
    const cred = await navigator.credentials.create({ publicKey: options, signal: over.signal, mediation: over.mediation });
    return { cred, options };
  }
  async function get(over = {}) {
    const options = {
      challenge: over.challenge || rand(32),
      rpId: over.rpId || rpId,
      allowCredentials: over.allowCredentials || [],
      userVerification: over.userVerification || "preferred",
      extensions: over.extensions,
      timeout: over.timeout || 20000,
    };
    const cred = await navigator.credentials.get({ publicKey: options, mediation: over.mediation, signal: over.signal });
    return { cred, options };
  }
  const result = (pass, detail) => ({ pass, detail });
  const expectError = async (fn, name) => {
    try {
      await fn();
      return result(false, `resolved; expected ${name}`);
    } catch (e) {
      return result(errName(e) === name, `${errName(e)}: ${e && e.message}`);
    }
  };

  // authenticator: options for the DevTools virtual authenticator the runner
  // adds before the scenario (CDP WebAuthn.addVirtualAuthenticator).
  const platform = { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true };
  const S = {
    "create-platform": {
      authenticator: platform,
      async run() {
        const { cred, options } = await create({ authenticatorSelection: { authenticatorAttachment: "platform", residentKey: "required", userVerification: "required" } });
        const { problems } = checkClientData(cred, "webauthn.create", options.challenge);
        const f = flags(cred.response.getAuthenticatorData());
        if (!f.up || !f.uv || !f.at) problems.push(`flags ${JSON.stringify(f)}`);
        if (cred.type !== "public-key" || cred.authenticatorAttachment !== "platform") problems.push(`type/attachment ${cred.type}/${cred.authenticatorAttachment}`);
        if (typeof cred.toJSON !== "function") problems.push("no toJSON");
        return result(problems.length === 0, problems.join("; ") || "ok");
      },
    },
    "get-discoverable": {
      authenticator: platform,
      async run() {
        const userId = rand(16);
        await create({ userId });
        const { cred, options } = await get({ userVerification: "required" });
        const { problems } = checkClientData(cred, "webauthn.get", options.challenge);
        if (!cred.response.userHandle || !same(cred.response.userHandle, userId)) problems.push("userHandle missing or wrong");
        return result(problems.length === 0, problems.join("; ") || "ok");
      },
    },
    "get-allow-list": {
      authenticator: platform,
      async run() {
        const made = await create();
        const { cred, options } = await get({ allowCredentials: [{ type: "public-key", id: made.cred.rawId }] });
        const { problems } = checkClientData(cred, "webauthn.get", options.challenge);
        if (!same(cred.rawId, made.cred.rawId)) problems.push("other credential returned");
        return result(problems.length === 0, problems.join("; ") || "ok");
      },
    },
    // K12: Google sends a 10,832-byte challenge; the legacy bridge capped it at 1 KiB.
    "get-large-challenge": {
      authenticator: platform,
      async run() {
        await create();
        const challenge = rand(10832);
        const { cred } = await get({ challenge });
        const { problems } = checkClientData(cred, "webauthn.get", challenge);
        return result(problems.length === 0, problems.join("; ") || "ok");
      },
    },
    // K11: security keys return no user handle for non-discoverable credentials.
    "get-no-user-handle": {
      authenticator: { protocol: "ctap2", transport: "usb", hasResidentKey: false, hasUserVerification: false },
      async run() {
        const made = await create({ authenticatorSelection: { residentKey: "discouraged", userVerification: "discouraged" } });
        const { cred } = await get({ allowCredentials: [{ type: "public-key", id: made.cred.rawId, transports: ["usb"] }], userVerification: "discouraged" });
        const uh = cred.response.userHandle;
        return result(uh === null, uh === null ? "userHandle null" : `userHandle ${uh && uh.byteLength} bytes`);
      },
    },
    // K15: a pending conditional request must be abortable, and a modal request
    // after it must work.
    "abort-conditional-then-modal": {
      authenticator: platform,
      async run() {
        await create();
        if (!(await PublicKeyCredential.isConditionalMediationAvailable?.())) return result(null, "conditional mediation unavailable");
        const ac = new AbortController();
        const pending = get({ mediation: "conditional", signal: ac.signal }).then(() => "resolved", (e) => errName(e));
        ac.abort();
        const first = await pending;
        const { cred } = await get({ userVerification: "required" });
        const ok = first === "AbortError" && cred && cred.type === "public-key";
        return result(ok, `conditional: ${first}; modal: ${cred ? "ok" : "none"}`);
      },
    },
    "abort-modal": {
      authenticator: { ...platform, automaticPresenceSimulation: false },
      async run() {
        const ac = new AbortController();
        const pending = get({ signal: ac.signal }).then(() => "resolved", (e) => errName(e));
        setTimeout(() => ac.abort(), 200);
        const r = await pending;
        return result(r === "AbortError", r);
      },
    },
    "prf-create-get": {
      authenticator: { ...platform, hasPrf: true },
      async run() {
        const made = await create({ extensions: { prf: {} } });
        const enabled = made.cred.getClientExtensionResults().prf?.enabled;
        const salt = rand(32);
        const { cred } = await get({ allowCredentials: [{ type: "public-key", id: made.cred.rawId }], userVerification: "required", extensions: { prf: { eval: { first: salt } } } });
        const first = cred.getClientExtensionResults().prf?.results?.first;
        const ok = enabled === true && first && first.byteLength === 32;
        return result(!!ok, `enabled ${enabled}; first ${first ? first.byteLength : "none"} bytes`);
      },
    },
    "large-blob": {
      authenticator: { ...platform, ctap2Version: "ctap2_1", hasLargeBlob: true },
      async run() {
        const made = await create({ extensions: { largeBlob: { support: "required" } } });
        const supported = made.cred.getClientExtensionResults().largeBlob?.supported;
        const allow = [{ type: "public-key", id: made.cred.rawId }];
        const blob = enc.encode("cmux large blob");
        const w = await get({ allowCredentials: allow, extensions: { largeBlob: { write: blob } } });
        const written = w.cred.getClientExtensionResults().largeBlob?.written;
        const r = await get({ allowCredentials: allow, extensions: { largeBlob: { read: true } } });
        const read = r.cred.getClientExtensionResults().largeBlob?.blob;
        const ok = supported === true && written === true && read && same(read, blob);
        return result(!!ok, `supported ${supported}; written ${written}; read ${read ? dec.decode(read) : "none"}`);
      },
    },
    "cred-props": {
      authenticator: platform,
      async run() {
        const { cred } = await create({ extensions: { credProps: true } });
        const rk = cred.getClientExtensionResults().credProps?.rk;
        return result(rk === true, `rk ${rk}`);
      },
    },
    "client-capabilities": {
      authenticator: platform,
      async run() {
        if (typeof PublicKeyCredential.getClientCapabilities !== "function") return result(false, "getClientCapabilities missing");
        const caps = await PublicKeyCredential.getClientCapabilities();
        const json = typeof PublicKeyCredential.parseCreationOptionsFromJSON === "function";
        return result(json && typeof caps === "object", `json helpers ${json}; ${JSON.stringify(caps)}`);
      },
    },
    "user-id-too-long": {
      authenticator: platform,
      run: () => expectError(() => create({ userId: rand(65) }), "TypeError"),
    },
    "insecure-rp-id": {
      authenticator: platform,
      run: () => expectError(() => create({ rpId: "example.com" }), "SecurityError"),
    },
    // K8: record which UI/authenticator answers when descriptors list only
    // hybrid, or internal + hybrid (Google's shape). The virtual authenticator
    // cannot show what sheet a person would see; record only.
    "transports-hybrid-only": {
      authenticator: platform,
      async run() {
        const made = await create();
        try {
          await get({ allowCredentials: [{ type: "public-key", id: made.cred.rawId, transports: ["hybrid"] }], timeout: 3000 });
          return result(null, "resolved");
        } catch (e) {
          return result(null, errName(e));
        }
      },
    },
    "transports-internal-hybrid": {
      authenticator: platform,
      async run() {
        const made = await create();
        try {
          const { cred } = await get({ allowCredentials: [{ type: "public-key", id: made.cred.rawId, transports: ["internal", "hybrid"] }] });
          // Google's shape: the platform credential must answer (Chromium does).
          return result(cred.authenticatorAttachment === "platform", `resolved by ${cred.authenticatorAttachment}`);
        } catch (e) {
          return result(false, errName(e));
        }
      },
    },
    "cross-origin-iframe-denied": {
      authenticator: platform,
      frame: { allow: "", mode: "get" },
    },
    "cross-origin-iframe-allowed": {
      authenticator: platform,
      frame: { allow: "publickey-credentials-create *; publickey-credentials-get *", mode: "create", click: "#go" },
    },
    // Opaque-origin callers (R122): a sandboxed srcdoc frame without
    // allow-same-origin. The browser must reject, never abort (cmux's CEF
    // aborted on a DCHECK here until cmux.17). Pass = the frame answered.
    "opaque-origin-iframe-uvpa": {
      authenticator: platform,
      opaque: "uvpa",
    },
    "sandboxed-iframe-create": {
      authenticator: platform,
      opaque: "create",
    },
  };

  function opaqueFrameScenario(name, mode) {
    return new Promise((resolve) => {
      const id = Math.random().toString(36).slice(2);
      const call = mode === "uvpa"
        ? "PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then((v) => ({ ok: true, detail: 'resolved ' + v }))"
        : "navigator.credentials.create({ publicKey: { challenge: new Uint8Array(32), rp: { name: 'x' }, user: { id: new Uint8Array(8), name: 'u', displayName: 'u' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }], timeout: 5000 } }).then(() => ({ ok: false, detail: 'resolved; expected a rejection' }))";
      const f = document.createElement("iframe");
      f.sandbox = "allow-scripts";
      f.allow = "publickey-credentials-create *; publickey-credentials-get *";
      f.srcdoc = `<script>Promise.resolve().then(() => ${call}).catch((e) => ({ ok: true, detail: (e && e.name) + ': ' + (e && e.message) }))` +
        `.then((r) => parent.postMessage({ cmuxPasskeyOpaque: ${JSON.stringify(id)}, r }, '*'));<\/script>`;
      f.dataset.scenario = name;
      const onMessage = (event) => {
        if (event.data && event.data.cmuxPasskeyOpaque === id) {
          removeEventListener("message", onMessage);
          f.remove();
          resolve(result(event.data.r.ok, event.data.r.detail));
        }
      };
      addEventListener("message", onMessage);
      document.getElementById("frames").appendChild(f);
    });
  }

  // Cross-origin frames live on frame.localhost (another origin, same server).
  function frameScenario(name, spec) {
    return new Promise((resolve) => {
      const id = Math.random().toString(36).slice(2);
      const url = new URL("frame.html", location.href);
      url.hostname = "frame." + location.hostname;
      url.search = new URLSearchParams({ id, mode: spec.mode, top: location.origin, expect: spec.expect || "" }).toString();
      const f = document.createElement("iframe");
      f.src = url.href;
      if (spec.allow) f.allow = spec.allow;
      f.dataset.scenario = name;
      const onMessage = (event) => {
        if (event.data && event.data.cmuxPasskeyFrame === id) {
          removeEventListener("message", onMessage);
          f.remove();
          resolve(event.data.result);
        }
      };
      addEventListener("message", onMessage);
      document.getElementById("frames").appendChild(f);
    });
  }


  // Comprehensive matrix additions (passkeys.md section 7.1, 2026-10-16):
  // every transport and protocol the DevTools virtual authenticator offers,
  // user verification on and off, exclusion, attestation, several
  // credentials, timeouts, JSON helpers, signal methods, availability.
  const roaming = (transport, extra = {}) => ({ protocol: "ctap2", ctap2Version: "ctap2_1", transport, hasResidentKey: true, hasUserVerification: true, isUserVerified: true, ...extra });
  // fmt of an attestationObject (CBOR map; "fmt" is a short text key).
  function attestationFormat(attObj) {
    const b = new Uint8Array(attObj);
    for (let i = 0; i + 4 < b.length; i++) {
      if (b[i] === 0x63 && b[i + 1] === 0x66 && b[i + 2] === 0x6d && b[i + 3] === 0x74) {
        const h = b[i + 4];
        if (h >= 0x60 && h < 0x78) return dec.decode(b.slice(i + 5, i + 5 + (h - 0x60)));
      }
    }
    return "unparsed";
  }
  // Register on a roaming authenticator, then sign in with an allow list.
  async function roundTrip(transport, { uv = "required", rk = "required" } = {}) {
    const made = await create({ authenticatorSelection: { authenticatorAttachment: "cross-platform", residentKey: rk, userVerification: uv } });
    const problems = checkClientData(made.cred, "webauthn.create", made.options.challenge).problems;
    const transports = made.cred.response.getTransports ? made.cred.response.getTransports() : [];
    if (made.cred.authenticatorAttachment !== "cross-platform") problems.push(`attachment ${made.cred.authenticatorAttachment}`);
    const f = flags(made.cred.response.getAuthenticatorData());
    if (!f.up || !f.at) problems.push(`create flags ${JSON.stringify(f)}`);
    if (uv === "required" && !f.uv) problems.push("uv flag missing");
    const got = await get({ allowCredentials: [{ type: "public-key", id: made.cred.rawId, transports }], userVerification: uv });
    problems.push(...checkClientData(got.cred, "webauthn.get", got.options.challenge).problems);
    if (!same(got.cred.rawId, made.cred.rawId)) problems.push("other credential returned");
    return result(problems.length === 0, (problems.join("; ") || "ok") + `; transports ${JSON.stringify(transports)}`);
  }
  Object.assign(S, {
    "roundtrip-usb-ctap2": { authenticator: roaming("usb"), run: () => roundTrip("usb") },
    "roundtrip-usb-u2f": {
      authenticator: { protocol: "u2f", transport: "usb", hasResidentKey: false, hasUserVerification: false },
      async run() {
        const made = await create({ authenticatorSelection: { authenticatorAttachment: "cross-platform", residentKey: "discouraged", userVerification: "discouraged" } });
        const got = await get({ allowCredentials: [{ type: "public-key", id: made.cred.rawId, transports: ["usb"] }], userVerification: "discouraged" });
        const f = flags(got.cred.response.authenticatorData);
        const problems = checkClientData(got.cred, "webauthn.get", got.options.challenge).problems;
        if (!same(got.cred.rawId, made.cred.rawId)) problems.push("other credential returned");
        if (f.uv) problems.push("U2F cannot verify the user");
        if (got.cred.response.userHandle !== null) problems.push("U2F returned a user handle");
        return result(problems.length === 0, problems.join("; ") || "ok (U2F, no uv, no user handle)");
      },
    },
    "roundtrip-nfc": { authenticator: roaming("nfc"), run: () => roundTrip("nfc") },
    "roundtrip-ble": { authenticator: roaming("ble"), run: () => roundTrip("ble") },
    "roundtrip-hybrid": { authenticator: roaming("cable"), run: () => roundTrip("cable") },
    "roundtrip-usb-no-pin": {
      authenticator: roaming("usb", { hasUserVerification: false, isUserVerified: false, hasResidentKey: false }),
      run: () => roundTrip("usb", { uv: "discouraged", rk: "discouraged" }),
    },
    "uv-discouraged-no-uv": {
      authenticator: { ...platform, hasUserVerification: false, isUserVerified: false },
      async run() {
        const { cred } = await create({ authenticatorSelection: { residentKey: "preferred", userVerification: "discouraged" } });
        const f = flags(cred.response.getAuthenticatorData());
        return result(f.up && !f.uv, `flags ${JSON.stringify(f)}`);
      },
    },
    "uv-required-not-capable": {
      authenticator: roaming("usb", { hasUserVerification: false, isUserVerified: false }),
      run: () => expectError(() => create({ timeout: 5000, authenticatorSelection: { authenticatorAttachment: "cross-platform", residentKey: "discouraged", userVerification: "required" } }), "NotAllowedError"),
    },
    "exclude-credentials": {
      authenticator: platform,
      async run() {
        const first = await create();
        return expectError(() => create({ excludeCredentials: [{ type: "public-key", id: first.cred.rawId }] }), "InvalidStateError");
      },
    },
    "attestation-none": {
      authenticator: roaming("usb"),
      async run() {
        const { cred } = await create({ attestation: "none", authenticatorSelection: { authenticatorAttachment: "cross-platform", residentKey: "discouraged", userVerification: "discouraged" } });
        const fmt = attestationFormat(cred.response.attestationObject);
        return result(fmt === "none", `fmt ${fmt}`);
      },
    },
    // Chrome asks the person before it returns a security key's attestation;
    // with the virtual authenticator the UI is off, so record what comes back.
    "attestation-direct": {
      authenticator: roaming("usb"),
      async run() {
        const { cred } = await create({ attestation: "direct", authenticatorSelection: { authenticatorAttachment: "cross-platform", residentKey: "discouraged", userVerification: "discouraged" } });
        const fmt = attestationFormat(cred.response.attestationObject);
        return result(typeof fmt === "string" && fmt !== "unparsed" ? null : false, `fmt ${fmt}`);
      },
    },
    "multiple-credentials": {
      authenticator: platform,
      async run() {
        const a = await create({ userId: rand(16) });
        const b = await create({ userId: rand(16) });
        const onlyB = await get({ allowCredentials: [{ type: "public-key", id: b.cred.rawId }] });
        const either = await get({ allowCredentials: [{ type: "public-key", id: a.cred.rawId }, { type: "public-key", id: b.cred.rawId }] });
        const problems = [];
        if (!same(onlyB.cred.rawId, b.cred.rawId)) problems.push("allow list [B] returned another credential");
        if (!same(either.cred.rawId, a.cred.rawId) && !same(either.cred.rawId, b.cred.rawId)) problems.push("allow list [A, B] returned an unknown credential");
        return result(problems.length === 0, problems.join("; ") || "ok");
      },
    },
    "get-timeout": {
      authenticator: { ...platform, automaticPresenceSimulation: false },
      async run() {
        const began = Date.now();
        const r = await get({ timeout: 3000 }).then(() => "resolved", (e) => errName(e));
        const seconds = (Date.now() - began) / 1000;
        return result(r === "NotAllowedError" && seconds < 15, `${r} after ${seconds.toFixed(1)} s`);
      },
    },
    "get-unknown-credential": {
      authenticator: { ...platform, automaticPresenceSimulation: true },
      run: () => expectError(() => get({ timeout: 4000, allowCredentials: [{ type: "public-key", id: rand(32) }] }), "NotAllowedError"),
    },
    "conditional-mediation-available": {
      authenticator: platform,
      async run() {
        const v = await PublicKeyCredential.isConditionalMediationAvailable?.();
        return result(v === true, `isConditionalMediationAvailable ${v}`);
      },
    },
    // With a platform authenticator present (the virtual one here, the
    // profile/Touch ID one in a signed build) the page must see it: GitHub
    // shows "partial passkey support" when this is false (passkeys.md K19).
    "uvpa-with-platform-authenticator": {
      authenticator: platform,
      async run() {
        const v = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
        const caps = typeof PublicKeyCredential.getClientCapabilities === "function" ? await PublicKeyCredential.getClientCapabilities() : {};
        const ok = v === true && caps.userVerifyingPlatformAuthenticator === true && caps.passkeyPlatformAuthenticator === true;
        return result(ok, `uvpaa ${v}; caps.uvpa ${caps.userVerifyingPlatformAuthenticator}; caps.ppaa ${caps.passkeyPlatformAuthenticator}`);
      },
    },
    "client-capabilities-browser-features": {
      authenticator: platform,
      async run() {
        if (typeof PublicKeyCredential.getClientCapabilities !== "function") return result(false, "getClientCapabilities missing");
        const caps = await PublicKeyCredential.getClientCapabilities();
        // Hardware-independent: every Chromium build reports these true.
        const want = ["conditionalCreate", "conditionalGet", "relatedOrigins", "signalAllAcceptedCredentials", "signalCurrentUserDetails", "signalUnknownCredential", "extension:prf", "extension:largeBlob", "extension:credProps"];
        const missing = want.filter((k) => caps[k] !== true);
        return result(missing.length === 0, missing.length ? `not true: ${missing.join(", ")}; ${JSON.stringify(caps)}` : JSON.stringify(caps));
      },
    },
    "conditional-create": {
      authenticator: platform,
      async run() {
        // Chromium creates conditionally only right after a password sign-in;
        // record the answer (NotAllowedError without one).
        const r = await create({ mediation: "conditional", timeout: 4000 }).then(() => "resolved", (e) => errName(e));
        return result(r === "resolved" || r === "NotAllowedError" ? null : false, r);
      },
    },
    "json-helpers": {
      authenticator: platform,
      async run() {
        const P = PublicKeyCredential;
        if (typeof P.parseCreationOptionsFromJSON !== "function" || typeof P.parseRequestOptionsFromJSON !== "function") return result(false, "JSON parse helpers missing");
        const challenge = b64u(rand(32));
        const publicKey = P.parseCreationOptionsFromJSON({
          challenge, rp: { id: rpId, name: "cmux test RP" }, user: { id: b64u(rand(16)), name: "json@cmux.test", displayName: "json" },
          pubKeyCredParams: [{ type: "public-key", alg: -7 }], authenticatorSelection: { residentKey: "required", userVerification: "required" }, timeout: 20000,
        });
        const cred = await navigator.credentials.create({ publicKey });
        const json = cred.toJSON();
        const req = P.parseRequestOptionsFromJSON({ challenge: b64u(rand(32)), rpId, allowCredentials: [{ type: "public-key", id: json.id }], timeout: 20000 });
        const got = await navigator.credentials.get({ publicKey: req });
        const gj = got.toJSON();
        const ok = typeof json.response.clientDataJSON === "string" && json.id === cred.id && gj.id === json.id && typeof gj.response.signature === "string";
        return result(ok, `create.toJSON keys ${Object.keys(json.response).join(",")}; get id ${gj.id === json.id}`);
      },
    },
    "signal-apis": {
      authenticator: platform,
      async run() {
        const P = PublicKeyCredential;
        const names = ["signalUnknownCredential", "signalAllAcceptedCredentials", "signalCurrentUserDetails"];
        const missing = names.filter((n) => typeof P[n] !== "function");
        if (missing.length) return result(false, `missing ${missing.join(", ")}`);
        const made = await create();
        const userId = b64u(made.options.user.id);
        const outcomes = await Promise.all([
          P.signalUnknownCredential({ rpId, credentialId: b64u(rand(32)) }),
          P.signalAllAcceptedCredentials({ rpId, userId, allAcceptedCredentialIds: [made.cred.id] }),
          P.signalCurrentUserDetails({ rpId, userId, name: "agent@cmux.test", displayName: "cmux test" }),
        ].map((p) => p.then(() => "ok", (e) => errName(e))));
        return result(outcomes.every((o) => o === "ok"), outcomes.join(", "));
      },
    },
    "cross-origin-iframe-get-allowed": {
      authenticator: platform,
      frame: { allow: "publickey-credentials-create *; publickey-credentials-get *", mode: "create-get", click: "#go" },
    },
    "cross-origin-iframe-create-denied": {
      authenticator: platform,
      frame: { allow: "publickey-credentials-get *", mode: "create", click: "#go", expect: "NotAllowedError" },
    },
  });

  window.PASSKEY_SCENARIOS = S;
  window.passkeyHelpers = { create, get, checkClientData, flags, result, errName };
  window.runPasskeyScenario = async (name) => {
    const spec = S[name];
    if (!spec) return { name, pass: false, detail: "unknown scenario" };
    try {
      const r = spec.opaque ? await opaqueFrameScenario(name, spec.opaque)
        : spec.frame ? await frameScenario(name, spec.frame) : await spec.run();
      return { name, ...r };
    } catch (e) {
      return { name, pass: false, detail: `${errName(e)}: ${e && e.message}` };
    }
  };
})();

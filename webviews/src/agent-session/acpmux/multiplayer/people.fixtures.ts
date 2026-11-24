// l10n-allow-file: gallery and test fixtures (made-up people and prompts), not shipped UI.
// The people of the shared chat fixtures (Faces.gallery.tsx, SharedChat.gallery.ts, tests).
import type { Participant } from "./participants";

export const ANA: Participant = { id: "tailnet:ana@example.com", name: "Ana Ruiz" };
export const SAM: Participant = { id: "tailnet:sam@example.com", name: "Sam Okafor" };
export const MEI: Participant = { id: "tailnet:mei@example.com", name: "Mei Lin" };
export const JORDAN: Participant = { id: "tailnet:jordan@example.com", name: "Jordan Blake" };

/// A made-up profile picture (an inline SVG: a gallery or test page loads nothing from the network),
/// standing in for the https picture a signed-in guest's account has (`fromAvatar`).
export const AVATAR =
  "data:image/svg+xml;base64," +
  btoa(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">' +
      '<stop offset="0" stop-color="#f6b26b"/><stop offset="1" stop-color="#c2547a"/></linearGradient></defs>' +
      '<rect width="64" height="64" fill="url(#g)"/><circle cx="32" cy="25" r="11" fill="#fde8d7"/>' +
      '<path d="M12 60c2-12 10-19 20-19s18 7 20 19z" fill="#fde8d7"/></svg>',
  );

/// The same made-up picture as a PNG: a record's inline picture is kept only as png, jpeg, gif or webp
/// (participants.ts `picture`), so a fixture fed through the guest page's records uses this one.
export const AVATAR_PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAACPElEQVR42s3W1VIcURCA4X5I4m4kZNxnN0SIu7srRCDCIwQJEiw4BAkLYYEggYU7qtJV53ZmMz27Z+pU/Q/w3bTAWq20+kVa/SzlPkm5j/JKjbxSLS9/kJffy3/fyUtvlaUqZbFSWXyjLLxWFl4p8y/V+Rfqn+fq3DN17qk6+0SdfazNPNJmHmrZB1r2vjZ9T5u+q/2+o0/d1qdu6ZM39ckbeua6nrlmTFw1Jq4Yvy4b45eM8YvG2AVz7Lw5es4cPWuOnDFHTps/T5kglGb4pAVCaYYrLBBKM3QCQSJpho5bIJRm8BiCRNIMHrVAKM1AuQ1CaQaO2CCUpj9tg1CavhSCCtCsZ/sDi63p820ouoYVT9PrIYiDhhVD0+s6wEnDomp6HARx07BImh7bAepMUUEkTbeFIOKEk0EUTbfpAHXfUEEkzQ/DAer2I4Momi7dBeoupoJImi7NBeplIIMomk4VQcQ7RQWRNJ2KCzGuJj9Nh4ygWDeck6ZDciH2R8FD034YQQX8N0XXtJd5wPXbomraDiFIJE3bQQ+E0nwv9UAoTesBBImkad3vgVCaln0+FKIJG/vYmpa9PsTQRD8dVE3zHgRRNNTLyoquad7tA28NK6KmaReC+GtYUTRNO31IRsP6r+bbjhQkpmHl1zRuR1CCGlYeTeO2FBRrwqOXR9OwFUHJalhhmoYtKcizizmCQjT1mxGUuIYVqKnflAbqnSpWgZq6jQgKueG8QYGaug1pCPsouIOCNF9L0v8ARXibCd8U0e4AAAAASUVORK5CYII=";

/// Link guests signed in to cmux (`guest:<share>.<guest>`): one whose account has a picture, one
/// without (their initials).
export const GUEST_WITH_AVATAR: Participant = { id: "guest:share-g.guest-1", name: "Priya Raman", avatar: AVATAR };
export const GUEST_INITIALS: Participant = { id: "guest:share-g.guest-2", name: "Tomás Ortega" };

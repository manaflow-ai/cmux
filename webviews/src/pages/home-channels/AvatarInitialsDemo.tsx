// l10n-allow-file: gallery fixtures (synthetic names), not shipped UI.
import { Avatar } from "./Avatar";

const names = ["Jo", "🦊 Fox", "👩🏽‍💻 Priya", "𠮷田", "e\u0301lodie"];

/** No avatar service or picture override: exercise the component's actual name fallback. */
export function AvatarInitialsDemo() {
  return (
    <table data-avatar-initials="" style={{ borderSpacing: "16px 12px", color: "var(--page-text)" }}>
      <thead>
        <tr>
          <th scope="col">Name</th>
          <th scope="col">20px</th>
          <th scope="col">24px</th>
        </tr>
      </thead>
      <tbody>
        {names.map((name, index) => {
          const participant = { id: `initial-person-${index}`, name, kind: "human" as const, chief: false };
          return (
            <tr key={participant.id}>
              <th scope="row" style={{ textAlign: "left", fontWeight: 400 }}>
                {name}
              </th>
              <td>
                <Avatar participant={participant} size={20} />
              </td>
              <td>
                <Avatar participant={participant} size={24} />
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

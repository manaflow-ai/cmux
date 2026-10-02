import { type CSSProperties } from "react";
import { Lock } from "./icons";

export type OpenElsewhereBannerProps = {
  title?: string;
  body?: string;
  actions?: string[];
  style?: CSSProperties;
};

/** "This is open in another app" banner that replaces the composer. */
export function OpenElsewhereBanner({
  title = "This is open in another app",
  body = "Close it there to continue here.",
  actions = ["Retry", "Fork chat"],
  style,
}: OpenElsewhereBannerProps) {
  return (
    <div className="cv-elsewhere" style={style}>
      <Lock className="cv-elsewhere__icon" size={16} strokeWidth={1.2} />
      <div className="cv-elsewhere__text">
        <div className="cv-elsewhere__title">{title}</div>
        <div className="cv-elsewhere__body">{body}</div>
      </div>
      <span className="cv-elsewhere__sep" />
      {actions.map((a) => (
        <span key={a} className="cv-elsewhere__action">
          {a}
        </span>
      ))}
    </div>
  );
}

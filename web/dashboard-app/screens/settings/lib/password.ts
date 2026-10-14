import { getPasswordError } from "@hexclave/shared/dist/helpers/password";

export type PasswordFieldErrors = {
  oldPassword?: "required";
  newPassword?: "required" | "tooShort" | "tooLong";
  newPasswordRepeat?: "required" | "mismatch";
};

export type PasswordFormValues = {
  readonly oldPassword: string;
  readonly newPassword: string;
  readonly newPasswordRepeat: string;
};

/** Hexclave's password length limits (see `getPasswordError`). */
export const PASSWORD_MIN_LENGTH = 8;
export const PASSWORD_MAX_LENGTH = 70;

/**
 * Client-side validation for the password form, matching Hexclave's yup
 * schema: old password required when one is set, new password passes
 * `getPasswordError`, and the repeat matches.
 */
export function validatePasswordForm(
  values: PasswordFormValues,
  hasPassword: boolean,
): PasswordFieldErrors {
  const errors: PasswordFieldErrors = {};
  if (hasPassword && values.oldPassword.length === 0) errors.oldPassword = "required";
  if (values.newPassword.length === 0) {
    errors.newPassword = "required";
  } else if (getPasswordError(values.newPassword)) {
    errors.newPassword = values.newPassword.length < PASSWORD_MIN_LENGTH ? "tooShort" : "tooLong";
  }
  if (values.newPasswordRepeat.length === 0) {
    errors.newPasswordRepeat = "required";
  } else if (values.newPasswordRepeat !== values.newPassword) {
    errors.newPasswordRepeat = "mismatch";
  }
  return errors;
}

export function hasPasswordErrors(errors: PasswordFieldErrors): boolean {
  return Object.values(errors).some(Boolean);
}

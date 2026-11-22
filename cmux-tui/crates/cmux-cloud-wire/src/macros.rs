//! The macros the generated code (`src/generated/`) expands. They keep the
//! generated files declarative: one invocation per enum, literal, error set
//! and op.

/// A catalog string enum with more than one value. A value this build does
/// not know decodes to `Unknown` and encodes back unchanged.
macro_rules! wire_enum {
    ($(#[$meta:meta])* $name:ident { $($(#[$vmeta:meta])* $variant:ident = $value:literal),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub enum $name {
            $($(#[$vmeta])* $variant,)+
            /// A value this build does not know (a newer backend), kept verbatim.
            Unknown(String),
        }

        impl $name {
            /// Every value this build knows, in catalog order.
            pub const KNOWN: &'static [&'static str] = &[$($value),+];

            /// The wire value.
            pub fn as_str(&self) -> &str {
                match self {
                    $(Self::$variant => $value,)+
                    Self::Unknown(value) => value,
                }
            }

            /// The variant of a wire value; `Unknown` when this build does not know it.
            pub fn from_wire(value: &str) -> Self {
                match value {
                    $($value => Self::$variant,)+
                    other => Self::Unknown(other.to_owned()),
                }
            }
        }

        impl ::serde::Serialize for $name {
            fn serialize<S: ::serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str(self.as_str())
            }
        }

        impl<'de> ::serde::Deserialize<'de> for $name {
            fn deserialize<D: ::serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                let value = <String as ::serde::Deserialize>::deserialize(deserializer)?;
                Ok(Self::from_wire(&value))
            }
        }
    };
}

/// A catalog single-value string enum: a strict literal (it decodes only
/// from its one value), as union discriminators need.
macro_rules! wire_literal {
    ($(#[$meta:meta])* $name:ident = $value:literal) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
        pub struct $name;

        impl $name {
            /// The one wire value.
            pub const VALUE: &'static str = $value;
        }

        impl ::serde::Serialize for $name {
            fn serialize<S: ::serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str(Self::VALUE)
            }
        }

        impl<'de> ::serde::Deserialize<'de> for $name {
            fn deserialize<D: ::serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                let value = <String as ::serde::Deserialize>::deserialize(deserializer)?;
                if value == Self::VALUE {
                    Ok(Self)
                } else {
                    Err(<D::Error as ::serde::de::Error>::invalid_value(
                        ::serde::de::Unexpected::Str(&value),
                        &Self::VALUE,
                    ))
                }
            }
        }
    };
}

/// The error codes of one op ([`crate::WireError`]); a code the op does not
/// declare decodes to `Unknown` and encodes back unchanged.
macro_rules! wire_errors {
    ($(#[$meta:meta])* $name:ident { $($variant:ident = $code:literal),* $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, PartialEq, Eq, Hash)]
        pub enum $name {
            $($variant,)*
            /// A code this op does not declare (a newer backend), kept verbatim.
            Unknown(String),
        }

        impl $crate::WireError for $name {
            const CODES: &'static [&'static str] = &[$($code),*];

            fn code(&self) -> &str {
                match self {
                    $(Self::$variant => $code,)*
                    Self::Unknown(code) => code,
                }
            }

            fn from_code(code: &str) -> Self {
                match code {
                    $($code => Self::$variant,)*
                    other => Self::Unknown(other.to_owned()),
                }
            }

            fn is_declared(&self) -> bool {
                !matches!(self, Self::Unknown(_))
            }
        }

        impl ::serde::Serialize for $name {
            fn serialize<S: ::serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                $crate::op::serialize_error(self, serializer)
            }
        }

        impl<'de> ::serde::Deserialize<'de> for $name {
            fn deserialize<D: ::serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                $crate::op::deserialize_error(deserializer)
            }
        }
    };
}

/// One op marker type and its [`crate::Op`] impl.
macro_rules! wire_op {
    (
        $(#[$meta:meta])*
        $name:ident {
            name: $op:literal,
            class: $class:ident,
            idempotency: $idempotency:ident,
            owner: $owner:literal,
            risk: $risk:literal,
            principals: [$($principal:ident),* $(,)?],
            params: $params:ty,
            result: $result:ty,
            error: $error:ty $(,)?
        }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
        pub struct $name;

        impl $crate::Op for $name {
            const NAME: &'static str = $op;
            const CLASS: $crate::WireClass = $crate::WireClass::$class;
            const IDEMPOTENCY: $crate::WireIdempotency = $crate::WireIdempotency::$idempotency;
            const OWNER: &'static str = $owner;
            const RISK: &'static str = $risk;
            const PRINCIPALS: &'static [$crate::WirePrincipal] = &[$($crate::WirePrincipal::$principal),*];
            type Params = $params;
            type Result = $result;
            type Error = $error;
        }
    };
}

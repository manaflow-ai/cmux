<img src="assets/header-round-medium.png" width="100%" align="center" />

<p align="right">
  <i>If you use this repo, star it ✨</i>
</p>

# Stop typing twice 🙅‍♂️

A lot of projects use JSON schemas for runtime data validation along with TypeScript for static type checking.

Their code may look like this:

```typescript
const dogSchema = {
  type: "object",
  properties: {
    name: { type: "string" },
    age: { type: "integer" },
    hobbies: { type: "array", items: { type: "string" } },
    favoriteFood: { enum: ["pizza", "taco", "fries"] },
  },
  required: ["name", "age"],
};

type Dog = {
  name: string;
  age: number;
  hobbies?: string[];
  favoriteFood?: "pizza" | "taco" | "fries";
};
```

Both objects carry similar if not exactly the same information. This is a code duplication that can annoy developers and introduce bugs if not properly maintained.

That's when `json-schema-to-ts` comes to the rescue 💪

## FromSchema

The `FromSchema` method lets you infer TS types directly from JSON schemas:

```typescript
import { FromSchema } from "json-schema-to-ts";

const dogSchema = {
  type: "object",
  properties: {
    name: { type: "string" },
    age: { type: "integer" },
    hobbies: { type: "array", items: { type: "string" } },
    favoriteFood: { enum: ["pizza", "taco", "fries"] },
  },
  required: ["name", "age"],
} as const;

type Dog = FromSchema<typeof dogSchema>;
// => Will infer the same type as above
```

Schemas can even be nested, as long as you don't forget the `as const` statement:

```typescript
const catSchema = { ... } as const;

const petSchema = {
  anyOf: [dogSchema, catSchema],
} as const;

type Pet = FromSchema<typeof petSchema>;
// => Will work 🙌
```

> The `as const` statement is used so that TypeScript takes the schema definition to the word (e.g. _true_ is interpreted as the _true_ constant and not widened as _boolean_). It is pure TypeScript and has zero impact on the compiled code.

## Why use `json-schema-to-ts`?

If you're looking for runtime validation with added types, libraries like [yup](https://github.com/jquense/yup), [zod](https://github.com/vriad/zod) or [runtypes](https://github.com/pelotom/runtypes) may suit your needs while being easier to use!

On the other hand, JSON schemas have the benefit of being widely used, more versatile and reusable (swaggers, APIaaS...).

If you prefer to stick to them and can define your schemas in TS instead of JSON (importing JSONs `as const` is not available yet), then `json-schema-to-ts` is made for you:

- ✅ **Schema validation** `FromSchema` raises TS errors on invalid schemas, based on [DefinitelyTyped](https://github.com/DefinitelyTyped/DefinitelyTyped/tree/master/types/json-schema)'s definitions
- ✨ **No impact on compiled code**: `json-schema-to-ts` only operates in type space. And after all, what's lighter than a dev-dependency?
- 🍸 **DRYness**: Less code means less embarrassing typos
- 🤝 **Consistency**: See that `string` that you used instead of an `enum`? Or this `additionalProperties` you confused with `additionalItems`? Or forgot entirely? Well, `json-schema-to-ts` does!
- 🔧 **Reliability**: `FromSchema` is extensively tested against [AJV](https://github.com/ajv-validator/ajv), and covers all the use cases that can be handled by TS for now\*
- 🏋️‍♂️ **Help on complex schemas**: Get complex schemas right first time with instantaneous typing feedbacks! For instance, it's not obvious the following schema can never be validated:

```typescript
const addressSchema = {
  type: "object",
  allOf: [
    {
      properties: {
        street: { type: "string" },
        city: { type: "string" },
        state: { type: "string" },
      },
      required: ["street", "city", "state"],
    },
    {
      properties: {
        type: { enum: ["residential", "business"] },
      },
    },
  ],
  additionalProperties: false,
} as const;
```

But it is with `FromSchema`!

```typescript
type Address = FromSchema<typeof addressSchema>;
// => never 🙌
```

> \*If `json-schema-to-ts` misses one of your use case, feel free to [open an issue](https://github.com/ThomasAribart/json-schema-to-ts/issues) 🤗

## Table of content

- [Installation](#installation)
- [Use cases](#use-cases)
  - [Const](#const)
  - [Enums](#enums)
  - [Primitive types](#primitive-types)
  - [Arrays](#arrays)
  - [Tuples](#tuples)
  - [Objects](#objects)
- [Combining schemas](#combining-schemas)
  - [AnyOf](#anyof)
  - [AllOf](#allof)
  - [OneOf](#oneof)
  - [Not](#not)
  - [If/Then/Else](#ifthenelse)
- [Definitions](#definitions)

## Installation

```bash
# npm
npm install --save-dev json-schema-to-ts

# yarn
yarn add --dev json-schema-to-ts
```

> `json-schema-to-ts` requires TypeScript 3.3+. Activating `strictNullChecks` or using `strict` mode is recommended.

## Use cases

### Const

```typescript
const fooSchema = {
  const: "foo",
} as const;

type Foo = FromSchema<typeof fooSchema>;
// => "foo"
```

### Enums

```typescript
const enumSchema = {
  enum: [true, 42, { foo: "bar" }],
} as const;

type Enum = FromSchema<typeof enumSchema>;
// => true | 42 | { foo: "bar"}
```

You can also go full circle with typescript `enums`.

```typescript
enum Food {
  Pizza = "pizza",
  Taco = "taco",
  Fries = "fries",
}

const enumSchema = {
  enum: Object.values(Food),
} as const;

type Enum = FromSchema<typeof enumSchema>;
// => Food
```

### Primitive types

```typescript
const primitiveTypeSchema = {
  type: "null", // "boolean", "string", "integer", "number"
} as const;

type PrimitiveType = FromSchema<typeof primitiveTypeSchema>;
// => null, boolean, string or number
```

```typescript
const primitiveTypesSchema = {
  type: ["null", "string"],
} as const;

type PrimitiveTypes = FromSchema<typeof primitiveTypesSchema>;
// => null | string
```

> For more complex types, refinment keywords like `required` or `additionalItems` will apply 🙌

### Arrays

```typescript
const arraySchema = {
  type: "array",
  items: { type: "string" },
} as const;

type Array = FromSchema<typeof arraySchema>;
// => string[]
```

### Tuples

```typescript
const tupleSchema = {
  type: "array",
  items: [{ type: "boolean" }, { type: "string" }],
} as const;

type Tuple = FromSchema<typeof tupleSchema>;
// => [] | [boolean] | [boolean, string] | [boolean, string, ...unknown[]]
```

`FromSchema` supports the `additionalItems` keyword:

```typescript
const tupleSchema = {
  type: "array",
  items: [{ type: "boolean" }, { type: "string" }],
  additionalItems: false,
} as const;

type Tuple = FromSchema<typeof tupleSchema>;
// => [] | [boolean] | [boolean, string]
```

```typescript
const tupleSchema = {
  type: "array",
  items: [{ type: "boolean" }, { type: "string" }],
  additionalItems: { type: "number" },
} as const;

type Tuple = FromSchema<typeof tupleSchema>;
// => [] | [boolean] | [boolean, string] | [boolean, string, ...number[]]
```

...as well as the `minItems` and `maxItems` keywords:

```typescript
const tupleSchema = {
  type: "array",
  items: [{ type: "boolean" }, { type: "string" }],
  minItems: 1,
  maxItems: 2,
} as const;

type Tuple = FromSchema<typeof tupleSchema>;
// => [boolean] | [boolean, string]
```

> Additional items will only work if Typescript's `strictNullChecks` option is activated

### Objects

```typescript
const objectSchema = {
  type: "object",
  properties: {
    foo: { type: "string" },
    bar: { type: "number" },
  },
  required: ["foo"],
} as const;

type Object = FromSchema<typeof objectSchema>;
// => { [x: string]: unknown; foo: string; bar?: number; }
```

`FromSchema` partially supports the `additionalProperties` and `patternProperties` keywords:

- `additionalProperties` can be used to deny additional properties.

```typescript
const closedObjectSchema = {
  ...objectSchema,
  additionalProperties: false,
} as const;

type Object = FromSchema<typeof closedObjectSchema>;
// => { foo: string; bar?: number; }
```

- Used on their own, `additionalProperties` and/or `patternProperties` can be used to type unnamed properties.

```typescript
const openObjectSchema = {
  type: "object",
  additionalProperties: {
    type: "boolean",
  },
  patternProperties: {
    "^S": { type: "string" },
    "^I": { type: "integer" },
  },
} as const;

type Object = FromSchema<typeof openObjectSchema>;
// => { [x: string]: string | number | boolean }
```

- However, when used in combination with the `properties` keyword, extra properties will always be typed as `unknown` to avoid conflicts.

## Combining schemas

### AnyOf

```typescript
const anyOfSchema = {
  anyOf: [
    { type: "string" },
    {
      type: "array",
      items: { type: "string" },
    },
  ],
} as const;

type AnyOf = FromSchema<typeof anyOfSchema>;
// => string | string[]
```

`FromSchema` will correctly infer factored schemas:

```typescript
const factoredSchema = {
  type: "object",
  properties: {
    bool: { type: "boolean" },
  },
  required: ["bool"],
  anyOf: [
    {
      properties: {
        str: { type: "string" },
      },
      required: ["str"],
    },
    {
      properties: {
        num: { type: "number" },
      },
    },
  ],
} as const;

type Factored = FromSchema<typeof factoredSchema>;
// => {
//  [x:string]: unknown;
//  bool: boolean;
//  str: string;
// } | {
//  [x:string]: unknown;
//  bool: boolean;
//  num?: number;
// }
```

### OneOf

For the moment, `FromSchema` will use the `oneOf` keyword in the same way as `anyOf`:

```typescript
const catSchema = {
  type: "object",
  oneOf: [
    {
      properties: {
        name: { type: "string" },
      },
      required: ["name"],
    },
    {
      properties: {
        color: { enum: ["black", "brown", "white"] },
      },
    },
  ],
} as const;

type Cat = FromSchema<typeof catSchema>;
// => {
//  [x: string]: unknown;
//  name: string;
// } | {
//  [x: string]: unknown;
//  color?: "black" | "brown" | "white";
// }

// => Error will NOT be raised 😱
const invalidCat: Cat = { name: "Garfield" };
```

> This may be revised soon now that `not` exclusions are now possible

### AllOf

```typescript
const addressSchema = {
  type: "object",
  allOf: [
    {
      properties: {
        address: { type: "string" },
        city: { type: "string" },
        state: { type: "string" },
      },
      required: ["address", "city", "state"],
    },
    {
      properties: {
        type: { enum: ["residential", "business"] },
      },
    },
  ],
} as const;

type Address = FromSchema<typeof addressSchema>;
// => {
//   [x: string]: unknown;
//   address: string;
//   city: string;
//   state: string;
//   type?: "residential" | "business";
// }
```

### Not

```typescript
const tupleSchema = {
  type: "array",
  items: [{ const: 1 }, { const: 2 }],
  additionalItems: false,
  not: {
    const: [1],
  },
} as const;

type Tuple = FromSchema<typeof tupleSchema>;
// => [] | [1, 2]
```

```typescript
const primitiveTypeSchema = {
  not: {
    type: ["array", "object"],
  },
} as const;

type PrimitiveType = FromSchema<typeof primitiveTypeSchema>;
// => null | boolean | number | string
```

In objects and tuples, the exclusion will propagate to properties/items if it can collapse on a single one.

```typescript
// 👍 Can be propagated on "animal" property
const petSchema = {
  type: "object",
  properties: {
    animal: { enum: ["cat", "dog", "boat"] },
  },
  not: {
    properties: { animal: { const: "boat" } },
  },
  required: ["animal"],
  additionalProperties: false,
} as const;

type Pet = FromSchema<typeof petSchema>;
// => { animal: "cat" | "dog" }
```

```typescript
// ❌ Cannot be propagated
const petSchema = {
  type: "object",
  properties: {
    animal: { enum: ["cat", "dog"] },
    color: { enum: ["black", "brown", "white"] },
  },
  not: {
    const: { animal: "cat", color: "white" },
  },
  required: ["animal", "color"],
  additionalProperties: false,
} as const;

type Pet = FromSchema<typeof petSchema>;
// => { animal: "cat" | "dog", color: "black" | "brown" | "white" }
```

As some actionable keywords are not yet parsed, exclusions that resolve to `never` are granted the benefit of the doubt and omitted. For the moment, `FromSchema` assumes that you are not crafting unvalidatable exclusions.

```typescript
const oddNumberSchema = {
  type: "number",
  not: { multipleOf: 2 },
} as const;

type OddNumber = FromSchema<typeof oddNumberSchema>;
// => should and will resolve to "number"

const incorrectSchema = {
  type: "number",
  not: { bogus: "option" },
} as const;

type Incorrect = FromSchema<typeof incorrectSchema>;
// => should resolve to "never" but will still resolve to "number"
```

Also, keep in mind that TypeScript misses [refinment types](https://en.wikipedia.org/wiki/Refinement_type):

```typescript
const goodLanguageSchema = {
  type: "string",
  not: {
    enum: ["Bummer", "Silly", "Lazy sod !"],
  },
} as const;

type GoodLanguage = FromSchema<typeof goodLanguageSchema>;
// => string
```

### If/Then/Else

```typescript
const petSchema = {
  type: "object",
  properties: {
    animal: { enum: ["cat", "dog"] },
    dogBreed: { enum: Object.values(DogBreed) },
    catBreed: { enum: Object.values(CatBreed) },
  },
  required: ["animal"],
  additionalProperties: false,
  if: {
    properties: {
      animal: { const: "dog" },
    },
  },
  then: {
    required: ["dogBreed"],
    not: { required: ["catBreed"] },
  },
  else: {
    required: ["catBreed"],
    not: { required: ["dogBreed"] },
  },
} as const;

type Pet = FromSchema<typeof petSchema>;
// => { animal: "dog"; dogBreed: DogBreed }
// | { animal: "cat"; catBreed: CatBreed }
```

> `FromSchema` computes the resulting type as `(If ∩ Then) ∪ (¬If ∩ Else)`. While correct in theory, remember that the `not` keyword is not perfectly assimilated, which may become an issue in some complex schemas.

## Definitions

Since the introduction of [template literal types](https://www.typescriptlang.org/docs/handbook/2/template-literal-types.html) with Typescript 4.1, the `definitions` keyword seems implementable in `json-schema-to-ts`.

I'll soon be looking into it. Meanwhile, feel free to [open an issue](https://github.com/ThomasAribart/json-schema-to-ts/issues) 🤗

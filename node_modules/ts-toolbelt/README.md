<p align="center">
  <a href="https://github.com/millsp/ts-toolbelt">
    <img alt="logo" title="ts-toolbelt" src="https://raw.githubusercontent.com/millsp/ts-toolbelt/master/.github/logo.png" width="175" alt="Logo">
  </a>
  <h1 align="center">ts-toolbelt</h1>
  <h4 align="center">Higher Type Safety for TypeScript. A collection of useful types.</h4>
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/ts-toolbelt" >
    <img src="https://img.shields.io/npm/v/ts-toolbelt.svg">
  </a>
  <a href="https://travis-ci.org/millsp/ts-toolbelt" >
    <img src="https://img.shields.io/travis/millsp/ts-toolbelt.svg">
  </a>
  <a href="#">
    <img src="https://img.shields.io/npm/dm/ts-toolbelt.svg">
  </a>
  <a href="https://lgtm.com/projects/g/millsp/ts-toolbelt/context:javascript">
    <img alt="Language grade: JavaScript" src="https://img.shields.io/lgtm/grade/javascript/g/millsp/ts-toolbelt.svg?logo=lgtm&logoWidth=-2"/>
  </a>
  <a href="#">
    <img src="http://isitmaintained.com/badge/resolution/millsp/ts-toolbelt.svg"/>
  </a>
</p>

<p align="center">
  <a href="https://gitter.im/ts-toolbelt/community?utm_source=share-link&utm_medium=link&utm_campaign=share-link" >
    <img src="https://img.shields.io/gitter/room/ts-toolbelt/community.svg">
  </a>
  <a href="http://makeapullrequest.com" >
    <img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg">
  </a>
  <a href="https://conventionalcommits.org" >
    <img src="https://img.shields.io/badge/Conventional%20Commits-1.0.0-green.svg">
  </a>
  <a href="https://github.com/millsp/ts-toolbelt/blob/master/CODE_OF_CONDUCT.md" >
    <img src="https://img.shields.io/badge/CoC-Contributor%20Covenant-green.svg">
  </a>
  <a href="#">
    <img src="https://img.shields.io/npm/l/ts-toolbelt.svg">
  </a>
</p>

<p align="center">
  <a href="https://www.buymeacoffee.com/millsp" >
    <img src="https://raw.githubusercontent.com/millsp/ts-toolbelt/master/.github/donate.svg" height="20px" alt="Donate">
  </a>
  <a href="https://patreon.com/pirix" >
    <img src="https://raw.githubusercontent.com/millsp/ts-toolbelt/master/.github/patreon.svg" height="20px" alt="Support Me">
  </a>
  <a href="https://issuehunt.io/r/millsp/ts-toolbelt" >
    <img src="https://raw.githubusercontent.com/millsp/ts-toolbelt/master/.github/issuehunt.svg" height="20px" alt="Fund an Issue">
  </a>
  <a href="https://tidelift.com/subscription/pkg/npm-ts-toolbelt?utm_source=npm-ts-toolbelt&utm_medium=referral&utm_campaign=readme" >
    <img src="https://raw.githubusercontent.com/millsp/ts-toolbelt/master/.github/tidelift.svg" height="20px" alt="Join Tidelift">
  </a>
</p>

<p align="center">
  <a href="https://millsp.github.io/ts-toolbelt/">📖 Read Docs</a>
  ·
  <a href="#demo">🎮 View Demo</a>
  ·
  <a href="https://github.com/millsp/ts-toolbelt/issues/new?template=---bug-report.md" alt="Bug Report">🐞 Report Bug</a>
  ·
  <a href="https://github.com/millsp/ts-toolbelt/issues/new?template=---feature-request.md" alt="Request Feature">🍩 Request Feature</a>
  ·
  <a href="https://github.com/millsp/ts-toolbelt/issues/new?template=---question.md" alt="Ask Questions">🤔 Ask Questions</a>
</p>

## Table of Contents

* [📜 About](#-about)
* [🍩 Features](#-features)
* [🏁 Getting started](#-getting-started)
* [📖 Documentation](#-documentation-)
* [🧠 Good to know](#-good-to-know-)
* [📣 Announcements](#-announcements-)
* [🎁 Contributing](#-contributing)
* [💉 Running tests](#-running-tests)
* [🔧 Compatibility](#-compatibility)
* [👏 Sponsoring issues](#-sponsoring-issues)
* [🔮 What's next](#-whats-next)
* [🙏 Acknowledgements](#-acknowledgements)

## 📜 About

<h4 align="center"><i>"Avoid bugs by writing high quality types"</i></h4><br>

**ts-toolbelt** ships **utility types** that provide simple ways to **update**, **change**, and **compute** TypeScript types.
It offers unique dynamic features, allowing you to write type-safe software more **easily** and in **less time** than you do today.

Its programmatic API brings **new capabilities** to TypeScript with **+200** tested type utilities. This makes it the largest and the most reliable type collection out there.
It uses the type system itself for TypeScript to compute complex types. So its API exposes types that trade **CPU & RAM** for higher type safety.

### Goals

* Answer the question to **"How can I do this in TypeScript?"**
* Provide a programmatic **standard API** for the type system
* Promote type **evolution**/**reusability** within your codebase
* Software that is more **type-safe**, **flexible**, and **robust**
* Bring a whole new set of extra **features** to TypeScript
* Extensively tested type utilities for maximum type safety
* This package aims to be the home of all **utility types**
* [Answer questions about types and share knowledge](#-good-to-know-)

You'll find all the types you can ever need in this single and **well organized** package.

## 🍩 Features

Here's some of the most useful utilities:

* [Merge two types together](https://millsp.github.io/ts-toolbelt/modules/_object_merge_.html)
* [Update the field of a type](https://millsp.github.io/ts-toolbelt/modules/_object_update_.html)
* [Make some fields optional](https://millsp.github.io/ts-toolbelt/modules/_object_optional_.html)
* [Change a type at any depth!](https://millsp.github.io/ts-toolbelt/modules/_object_p_update_.html)
* [Concat two lists together](https://millsp.github.io/ts-toolbelt/modules/_list_concat_.html)
* [Get the last item of a list](https://millsp.github.io/ts-toolbelt/modules/_list_last_.html)

<p align="center">
  <img src="https://raw.githubusercontent.com/millsp/ts-toolbelt/master/.github/demo.gif" id="demo" width="750px">
<p align="center">

> **`TIP`** If you don't find the type you are looking for, you are welcome to open a [feature request](https://github.com/millsp/ts-toolbelt/issues/new?template=---feature-request.md)!

## 🏁 Getting Started

### Prerequisites

Lowest TypeScript [support](#-compatibility) starts at v3.5

```sh
npm install typescript@^3.8.0 --save-dev
```

For best results, add this to your `tsconfig.json`

```ts
{
  "compilerOptions": {
    // highly recommended (required by few utilities)
    "strictNullChecks": true,

    // this is optional, but enable whenever possible
    "strict": true,

    // this is the lowest supported standard library
    "lib": [
        "es2015",
    ],
  }
}
```

### Installation

```sh
npm install ts-toolbelt --save
```

### Hello World

```ts
import {Object} from "ts-toolbelt"
// Check the docs below for more

// Merge two `object` together
type merge = Object.Merge<{name: string}, {age?: number}>
// {name: string, age?: number}

// Make a field of an `object` optional
type optional = Object.Optional<{id: number, name: string}, "name"}>
// {id: number, name?: string}
```

> **`TIP`** You can also grab the demo [over here](https://gist.github.com/millsp/f7f7d18773f79bf0618fb5cd55bd48f8).

You can [**level-up, and re-code this library from scratch**](https://medium.com/free-code-camp/typescript-curry-ramda-types-f747e99744ab).

## [📖 Documentation ⤢](https://millsp.github.io/ts-toolbelt/)

### Where to start

To get you started, we recommend that you visit the documentation of the following essential tools. 
| Object                                                                                | List                                                                        | Function                                                                              | Any                                                                              | Union                                                                                |
|---------------------------------------------------------------------------------------|-----------------------------------------------------------------------------|---------------------------------------------------------------------------------------|----------------------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| [Either](https://millsp.github.io/ts-toolbelt/modules/_object_either_.html)           | [Append](https://millsp.github.io/ts-toolbelt/modules/_list_append_.html)   | [NoInfer](https://millsp.github.io/ts-toolbelt/modules/_function_noinfer_.html)       | [Compute](https://millsp.github.io/ts-toolbelt/modules/_any_compute_.html)       | [Filter](https://millsp.github.io/ts-toolbelt/modules/_union_filter_.html)           |
| [Exclude](https://millsp.github.io/ts-toolbelt/modules/_object_exclude_.html)         | [Concat](https://millsp.github.io/ts-toolbelt/modules/_list_concat_.html)   | [Parameters](https://millsp.github.io/ts-toolbelt/modules/_function_parameters_.html) | [Promisable](https://millsp.github.io/ts-toolbelt/modules/_any_promisable_.html) | [IntersectOf](https://millsp.github.io/ts-toolbelt/modules/_union_intersectof_.html) |
| [Filter](https://millsp.github.io/ts-toolbelt/modules/_object_filter_.html)           | [Drop](https://millsp.github.io/ts-toolbelt/modules/_list_drop_.html)       | [Promisify](https://millsp.github.io/ts-toolbelt/modules/_function_promisify_.html)   | [Type](https://millsp.github.io/ts-toolbelt/modules/_any_type_.html)             | [Merge](https://millsp.github.io/ts-toolbelt/modules/_union_merge_.html)             |
| [Merge](https://millsp.github.io/ts-toolbelt/modules/_object_merge_.html)             | [Flatten](https://millsp.github.io/ts-toolbelt/modules/_list_flatten_.html) | [Return](https://millsp.github.io/ts-toolbelt/modules/_function_return_.html)         |                                                                                  | [Select](https://millsp.github.io/ts-toolbelt/modules/_union_select_.html)           |
| [NonNullable](https://millsp.github.io/ts-toolbelt/modules/_object_nonnullable_.html) | [Pop](https://millsp.github.io/ts-toolbelt/modules/_list_pop_.html)         |                                                                                       |                                                                                  | [Strict](https://millsp.github.io/ts-toolbelt/modules/_union_strict_.html)           |
| [Nullable](https://millsp.github.io/ts-toolbelt/modules/_object_nullable_.html)       | [Prepend](https://millsp.github.io/ts-toolbelt/modules/_list_prepend_.html) |                                                                                       |                                                                                  |                                                                                      |
| [Omit](https://millsp.github.io/ts-toolbelt/modules/_object_omit_.html)               | [Remove](https://millsp.github.io/ts-toolbelt/modules/_list_remove_.html)   |                                                                                       |                                                                                  |                                                                                      |
| [Optional](https://millsp.github.io/ts-toolbelt/modules/_object_optional_.html)       | [Reverse](https://millsp.github.io/ts-toolbelt/modules/_list_reverse_.html) |                                                                                       |                                                                                  |                                                                                      |
| [Overwrite](https://millsp.github.io/ts-toolbelt/modules/_object_overwrite_.html)     | [Tail](https://millsp.github.io/ts-toolbelt/modules/_list_tail_.html)       |                                                                                       |                                                                                  |                                                                                      |
| [P/Merge](https://millsp.github.io/ts-toolbelt/modules/_object_p/merge_.html)         |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [P/Omit](https://millsp.github.io/ts-toolbelt/modules/_object_p/omit_.html)           |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [P/Pick](https://millsp.github.io/ts-toolbelt/modules/_object_p/pick_.html)           |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [P/Update](https://millsp.github.io/ts-toolbelt/modules/_object_p/update_.html)       |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [Path](https://millsp.github.io/ts-toolbelt/modules/_object_path_.html)               |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [Pick](https://millsp.github.io/ts-toolbelt/modules/_object_pick_.html)               |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [Readonly](https://millsp.github.io/ts-toolbelt/modules/_object_readonly_.html)       |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [Required](https://millsp.github.io/ts-toolbelt/modules/_object_required_.html)       |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [Select](https://millsp.github.io/ts-toolbelt/modules/_object_select_.html)           |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [Unionize](https://millsp.github.io/ts-toolbelt/modules/_object_unionize_.html)       |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [UnionOf](https://millsp.github.io/ts-toolbelt/modules/_object_unionof_.html)         |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [Update](https://millsp.github.io/ts-toolbelt/modules/_object_update_.html)           |                                                                             |                                                                                       |                                                                                  |                                                                                      |
| [Writable](https://millsp.github.io/ts-toolbelt/modules/_object_writable_.html)       |                                                                             |                                                                                       |                                                                                  |                                                                                      |

> **`TIP`** [Add something to this list](https://github.com/millsp/ts-toolbelt/edit/master/README.md)

**The documentation is complete but it needs more examples**. So feel free to [ask for examples](https://github.com/millsp/ts-toolbelt/issues/new?template=---question.md).

### Imports

The project is organized around TypeScript's main concepts:

|            |             |                  |              |               |          |
|------------|-------------|------------------|--------------|---------------|----------|
| **A**ny    | **B**oolean | **C**lass        | **F**unction | **I**teration | **L**ist |
| **N**umber | **O**bject  | **O**bject.**P** | **S**tring   | **U**nion     | Test     |

> **`TIP`** How to choose categories? Match your type with them.

There are many ways to import the types into your project:

* **Explicit**
  ```ts
  import {Any, Boolean, Class, Function, Iteration, List, Number, Object, String, Union} from "ts-toolbelt"
  ```

* **Compact**
  ```ts
  import {A, B, C, F, I, L, N, O, S, U} from "ts-toolbelt"
  ```

* **Portable**
  ```ts
  import tb from "ts-toolbelt"
  ```

You can also import our non-official API from the community:
  ```ts
  import {Community} from "ts-toolbelt"
  ```

> **`TIP`** The community API is for our community to publish useful types that don't see fit in the standard API.

### Internal Docs

If you're interested to **learn** how the internals work, [this tutorial](https://medium.com/free-code-camp/typescript-curry-ramda-types-f747e99744ab) will get you on track to start writing your own types.

### [Archives ⤢](https://github.com/millsp/ts-toolbelt/tree/gh-pages)

Access older docs at https://millsp.github.io/ts-toolbelt/version/

> **`EXAMPLE`** https://millsp.github.io/ts-toolbelt/4.2.1/

## [🧠 Good to Know ⤢](https://github.com/millsp/ts-toolbelt/issues?q=label%3Aquestion+sort%3Areactions-%2B1-desc+label%3Awiki)

In this wiki, you will find some extra resources for your learning, and understanding.

**Are you missing something?** Participate to the open-wiki by [posting your questions](https://github.com/millsp/ts-toolbelt/issues/new?template=---question.md).

## [📣 Announcements ⤢](https://github.com/millsp/ts-toolbelt/issues?utf8=✓&q=is%3Aissue+label%3Aannouncement+sort%3Acreated-desc+)

Stay up to date with the latest announcements with this regular digest of important changes.

## 🎁 Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**. There are many ways to contribute to the project:

### Community

* [Help the community with answers on Gitter](https://gitter.im/ts-toolbelt/community?utm_source=share-link&utm_medium=link&utm_campaign=share-link)
* [Reporting bugs or requesting new features](https://github.com/millsp/ts-toolbelt/issues/new/choose)

### Codebase

* Improving existing documentation 
* Adding new types to the collection
* [Getting involved with things to do](#-whats-next)

### Pull Requests

1. [Read the tutorial](https://medium.com/free-code-camp/typescript-curry-ramda-types-f747e99744ab)

2. Fork the project

3. Clone your fork

4. Create a pr/**feature** branch

   ```sh
   git checkout -b pr/CoolFeature
   ```
   
5. Commit your changes

   You **must** follow the [conventional commit](https://conventionalcommits.org) to be able to commit
   ```sh
   git commit -m "feat(name): Added this CoolFeature"
   ```

6. [Run the tests](#-running-tests)

7. Push your changes

   ```sh
   npm run release -- --no-tags
   ```

8. Open a pull request

## 💉 Running tests

### For this project

To run the `lint` & `type` tests, simply run:

```sh
npm test
```

### For your project

Want to test your own types? Let's get started:

```ts
import {Number, Test} from "ts-toolbelt"

const {checks, check} = Test

checks([
    check<Number.Plus<"1", "30">, "31", Test.Pass>(),
    check<Number.Plus<"5", "-3">, "2",  Test.Pass>(),
])
```

> **`TIP`** Place it in a file that won't be executed, it's just for TypeScript to test types.

### Continuous Integration

The releases are done with Travis CI in stages & whenever a branch or PR is pushed:

- Tests are run with `npm test`
- Tests against [DefinitelyTyped](https://github.com/DefinitelyTyped/DefinitelyTyped/)
- Releases to npm@[branch-name]

If you wrote tests & would like your project to be tested too, please open an issue.

## 🔧 Compatibility

The project is maintained to adapt to the constant [changes of TypeScript](https://github.com/Microsoft/TypeScript/wiki/Roadmap):

| ts-toolbelt | typescript |
|-------------|------------|
| 6.x.x       | ^3.7.x     |
| 4.x.x       | ^3.5.x     |
| 2.x.x       | ^3.5.x     |
| 3.x.x       | ^3.5.x     |
| 1.x.x       | ~3.5.x     |

Major version numbers will upgrade whenever TypeScript had breaking changes (it happened that TS had breaking changes on minor versions). Otherwise, the release versions will naturally follow the semantic versioning.

## 👏 Sponsoring issues

**Sponsored issues have higher priority over non-critical issues**.

You can either request a new feature or a bug fix, and then fund it.

**The money will be transparently split with an issue's assignees.**

<a href="https://issuehunt.io/r/millsp/ts-toolbelt" >
  <img src="https://raw.githubusercontent.com/millsp/ts-toolbelt/master/.github/issuehunt.svg" height="25px">
</a>
<br>

## 🔮 What's next

* Automated performance tests
  ```sh
  # performance is checked manually with 
  npx tsc --noEmit --extendedDiagnostics
  ```

* Need to write more examples

## 🙏 Acknowledgements

Many, many thanks to all the [contributors](https://github.com/millsp/ts-toolbelt/graphs/contributors) and:

* [André Staltz](https://github.com/staltz)
* [Joe Calzaretta](https://github.com/jcalz)
* [Matt McCutchen](https://github.com/mattmccutchen)
* [Monroe Ekilah](https://github.com/ekilah)
* [Nathan S.-Sanders](https://github.com/sandersn)
* [Regev Brody](https://github.com/regevbr)
* [Titian C.-Dragomir](https://github.com/dragomirtitian)

## 💟 Friendly Projects

* [`eledoc`](https://github.com/millsp/eledoc) - 🌒 A material dark theme for TypeDoc 
* [`utility-types`](https://github.com/piotrwitek/utility-types) - Collection of utility types, complementing TypeScript built-in mapped types and aliases

## License

[![FOSSA Status](https://app.fossa.com/api/projects/git%2Bgithub.com%2Fpirix-gh%2Fts-toolbelt.svg?type=large)](https://app.fossa.com/projects/git%2Bgithub.com%2Fpirix-gh%2Fts-toolbelt?ref=badge_large)
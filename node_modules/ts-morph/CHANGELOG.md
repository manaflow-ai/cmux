# Change Log

All notable changes to this project will be documented in this file. See [standard-version](https://github.com/conventional-changelog/standard-version) for commit guidelines.

<a name="12.0.0"></a>
# [12.0.0](https://github.com/dsherret/ts-morph/compare/11.0.3...12.0.0) (2021-08-27)


### Bug Fixes

* **deno:** avoid importing code using unstable APIs ([2a0789c](https://github.com/dsherret/ts-morph/commit/2a0789c)) - Thanks [@wojpawlik](https://github.com/wojpawlik)!


### Features

* Typescript 4.4 support ([63c255b](https://github.com/dsherret/ts-morph/commit/63c255b))

### BREAKING CHANGES

* Upgraded to TS 4.4.



<a name="11.0.3"></a>
## [11.0.3](https://github.com/dsherret/ts-morph/compare/11.0.2...11.0.3) (2021-07-11)


### Bug Fixes

* [#1171](https://github.com/dsherret/ts-morph/issues/1171) - Ensure the program is not sometimes reset when inspecting a symbol ([a41b7b5](https://github.com/dsherret/ts-morph/commit/a41b7b5))
* [#1164](https://github.com/dsherret/ts-morph/issues/1164) - getting a type, manipulating, then inspecting the type may cause source file to no longer exist in project ([d8a651e](https://github.com/dsherret/ts-morph/commit/d8a651e))



<a name="11.0.1"></a>
## [11.0.1](https://github.com/dsherret/ts-morph/compare/11.0.0...11.0.1) (2021-05-27)


### Bug Fixes

* `Node.isReferenceFindableNode(node)` should return `true` for a constructor declaration. ([b8b0a39](https://github.com/dsherret/ts-morph/commit/b8b0a39))



<a name="11.0.0"></a>
# [11.0.0](https://github.com/dsherret/ts-morph/compare/10.1.0...11.0.0) (2021-05-26)


### Features

* [#1156](https://github.com/dsherret/ts-morph/issues/1156) - Add `ReferenceFindableNode` to `ConstructorDeclaration`. ([e192d41](https://github.com/dsherret/ts-morph/commit/e192d41))
* TypeScript 4.3 Support ([cd426a0](https://github.com/dsherret/ts-morph/commit/cd426a0))


### BREAKING CHANGES

* Upgraded to TS 4.3.



<a name="10.1.0"></a>
# [10.1.0](https://github.com/dsherret/ts-morph/compare/10.0.2...10.1.0) (2021-05-15)


### Bug Fixes

* Handle comma separated definitions with DefinitionInfo#getDeclarationNode ([#1158](https://github.com/dsherret/ts-morph/issues/1158)) ([a390e94](https://github.com/dsherret/ts-morph/commit/a390e94)) - Thanks [@IgorMinar](https://github.com/IgorMinar)!


### Features

* [#1157](https://github.com/dsherret/ts-morph/issues/1157) - Add `Node#asKind(kind: SyntaxKind)` and `Node#asKindOrThrow(kind: SyntaxKind)` methods. ([58bb5cc](https://github.com/dsherret/ts-morph/commit/58bb5cc))
* Add MappedTypeNode Wrapper - Only navigation methods for now ([#1146](https://github.com/dsherret/ts-morph/issues/1146)) ([f74a9e2](https://github.com/dsherret/ts-morph/commit/f74a9e2)) ([6b6f1f4](https://github.com/dsherret/ts-morph/commit/6b6f1f4)) - Thanks [@nicdard](https://github.com/nicdard)!



<a name="10.0.2"></a>
## [10.0.2](https://github.com/dsherret/ts-morph/compare/10.0.1...10.0.2) (2021-03-22)

* Reduce dependencies.



<a name="10.0.1"></a>
## [10.0.1](https://github.com/dsherret/ts-morph/compare/10.0.0...10.0.1) (2021-02-24)


### Bug Fixes

* Fix ts-morph declaration file. ([e51eb0a](https://github.com/dsherret/ts-morph/commit/e51eb0a))



<a name="10.0.0"></a>
# [10.0.0](https://github.com/dsherret/ts-morph/compare/9.1.0...10.0.0) (2021-02-24)


### Bug Fixes

* [#889](https://github.com/dsherret/ts-morph/issues/889) - Fix internal root directory check to work on windows. ([6b2963c](https://github.com/dsherret/ts-morph/commit/6b2963c))
* [#926](https://github.com/dsherret/ts-morph/issues/926) - `ExportedDeclarations` should include `SourceFile` and fixed handling of namespace exports. ([b6bda27](https://github.com/dsherret/ts-morph/commit/b6bda27))


### Features

* [#916](https://github.com/dsherret/ts-morph/issues/916) - Type  - Add literal related helper properties. ([fd0acc8](https://github.com/dsherret/ts-morph/commit/fd0acc8))
* [#924](https://github.com/dsherret/ts-morph/issues/924) - NamespaceDeclaration -> ModuleDeclaration ([3dd5c72](https://github.com/dsherret/ts-morph/commit/3dd5c72))
* Add `Node#getFlags()`. ([b9769c2](https://github.com/dsherret/ts-morph/commit/b9769c2))
* Add isKnownTypesPackageName option ([#909](https://github.com/dsherret/ts-morph/issues/909)) ([398d946](https://github.com/dsherret/ts-morph/commit/398d946))
* Bundle typescript package in ts-morph/common ([#934](https://github.com/dsherret/ts-morph/issues/934)) ([1cccd02](https://github.com/dsherret/ts-morph/commit/1cccd02))
* Upgrade to TS 4.2 ([8dacc4f](https://github.com/dsherret/ts-morph/commit/8dacc4f))


### BREAKING CHANGES

* Upgraded to TS 4.2 (see TypeScript blog for breaking changes).
* ts-morph did not properly support some ambient and all shorthand ambient module declarations. Now `NamespaceDeclaration` is `ModuleDeclaration`. You will need to rename anything that references "Namespace" and change it to "Module".
* The `ExportedDeclarations` union type now properly includes `SourceFile`. It previously could have done that anyway and your code might not have handled it.
* TypeScript is now bundled with ts-morph. You may still access TypeScript via `import { ts } from "ts-morph"` as you should have been doing anyway.
* The lib files/lib.d.ts files are now served from memory regardless of the file system host. If you want the old behaviour, specify a `libFolderPath` in the `Project` constructor's options.


<a name="9.1.0"></a>
# [9.1.0](https://github.com/dsherret/ts-morph/compare/9.0.0...9.1.0) (2020-11-26)


### Features

* Add Directory#getProject() ([bef39b8](https://github.com/dsherret/ts-morph/commit/bef39b8))
* Support providing file paths to `getRelativePathTo` and `getRelativePathToAsModuleSpecifier`. ([df43d12](https://github.com/dsherret/ts-morph/commit/df43d12))



<a name="9.0.0"></a>
# [9.0.0](https://github.com/dsherret/ts-morph/compare/8.2.0...9.0.0) (2020-11-21)


### Bug Fixes

* [#878](https://github.com/dsherret/ts-morph/issues/878) - Fix tsconfig file resolution ([#883](https://github.com/dsherret/ts-morph/issues/883)) ([23ab8f5](https://github.com/dsherret/ts-morph/commit/23ab8f5), [8c7e8ba](https://github.com/dsherret/ts-morph/commit/8c7e8ba)) - Thanks [@Zzzen](https://github.com/Zzzen)!

Previously ts-morph was incorrectly resolving files based on `rootDir` and `rootDirs`, but according to the nicely updated tsconfig documentation, these options have nothing to do with file resolution ([read more](https://www.typescriptlang.org/tsconfig#rootDir)). If you run into any trouble, try using `"include": ["./your-source-dir"]` at the top level of the config file instead of `"rootDir": ["./your-source-dir"]` in compiler options or please open an issue.


### Code Refactoring

* [#838](https://github.com/dsherret/ts-morph/issues/838) - `addFilesFromTsConfig` is now inverted to `skipAddingFilesFromTsConfig`. Default behaviour is the same. ([1fda310](https://github.com/dsherret/ts-morph/commit/1fda310))


### Features

* [#858](https://github.com/dsherret/ts-morph/issues/858) - Remove `BooleanLiteral` and replace with `TrueLiteral` and `FalseLiteral`. ([97f0873](https://github.com/dsherret/ts-morph/commit/97f0873))
* [#885](https://github.com/dsherret/ts-morph/issues/885) - Upgrade to TS 4.1 ([d5395f6](https://github.com/dsherret/ts-morph/commit/d5395f6))


### Performance Improvements

* [#881](https://github.com/dsherret/ts-morph/issues/881) - Implement `getProjectVersion` on `LanguageServiceHost` ([#884](https://github.com/dsherret/ts-morph/issues/884)) ([916ffb4](https://github.com/dsherret/ts-morph/commit/916ffb4), [646f797](https://github.com/dsherret/ts-morph/commit/646f797)) - Thanks [@geremih](https://github.com/geremih)!


### BREAKING CHANGES

* Upgraded to TS 4.1.
* `addFilesFromTsConfig` is now inverted to `skipAddingFilesFromTsConfig`. Default behaviour is the same.

This was done to make the option align with the other options.
* `BooleanLiteral` is now a type alias of `TrueLiteral` and `FalseLiteral`. This was done to match the same change made in the compiler API.



<a name="8.2.0"></a>
# [8.2.0](https://github.com/dsherret/ts-morph/compare/8.1.2...8.2.0) (2020-11-12)


### Features

* Add `Project#getConfigFileParsingDiagnostics`. ([3f9f252](https://github.com/dsherret/ts-morph/commit/3f9f252))



<a name="8.1.2"></a>
## [8.1.2](https://github.com/dsherret/ts-morph/compare/8.1.1...8.1.2) (2020-10-12)


### Bug Fixes

* Fixed adding const modifier to exported enum ([#875](https://github.com/dsherret/ts-morph/issues/875)) ([b539a07](https://github.com/dsherret/ts-morph/commit/b539a07)) - Thanks [@IKatsuba](https://github.com/IKatsuba)!



<a name="8.1.1"></a>
## [8.1.1](https://github.com/dsherret/ts-morph/compare/8.1.0...8.1.1) (2020-09-21)


### Bug Fixes

* [#867](https://github.com/dsherret/ts-morph/issues/867) - Inspecting and manipulating new expressions without parenthesis would throw. ([1e5c9c0](https://github.com/dsherret/ts-morph/commit/1e5c9c0))



<a name="8.1.0"></a>
# [8.1.0](https://github.com/dsherret/ts-morph/compare/0.8.0...8.1.0) (2020-08-25)


### Features

* [#803](https://github.com/dsherret/ts-morph/issues/803) - Standardize nodes with `getExpression()` method to be `ExpressionedNode`s. ([3550cbf](https://github.com/dsherret/ts-morph/commit/3550cbf))
* Add JSDocDeprecatedTag. ([d73c480](https://github.com/dsherret/ts-morph/commit/d73c480))



<a name="8.0.0"></a>
# [8.0.0](https://github.com/dsherret/ts-morph/compare/7.3.0...8.0.0) (2020-08-20)


### Bug Fixes

* [#853](https://github.com/dsherret/ts-morph/issues/853) - Fix nested sibling transformations ([59b31b1](https://github.com/dsherret/ts-morph/commit/59b31b1)) - Thanks [@vsiao](https://github.com/vsiao)!


### Features

* [#855](https://github.com/dsherret/ts-morph/issues/855) - Add Author, Callback, Enum, Implements JSDoc tags ([f5b4bc9](https://github.com/dsherret/ts-morph/commit/f5b4bc9)) - Thanks [@ilyaulyanov](https://github.com/ilyaulyanov)!
* [#857](https://github.com/dsherret/ts-morph/issues/857) - Upgrade to TypeScript 4.0 ([67017f9](https://github.com/dsherret/ts-morph/commit/67017f9))


### BREAKING CHANGES

* Upgraded to TypeScript 4.0

* `TupleTypeNode#getElementTypeNodes()` is now `getElements()` to match the change in the compiler API.



<a name="7.3.0"></a>
# [7.3.0](https://github.com/dsherret/ts-morph/compare/7.2.0...7.3.0) (2020-08-11)


### Features

* [#842](https://github.com/dsherret/ts-morph/issues/842) - Allow calling Node.is** functions with undefined value ([fff2cf8](https://github.com/dsherret/ts-morph/commit/fff2cf8)) - Thanks [@sisisin](https://github.com/sisisin)!



<a name="7.2.0"></a>
# [7.2.0](https://github.com/dsherret/ts-morph/compare/7.1.3...7.2.0) (2020-08-09)


### Bug Fixes

* [#840](https://github.com/dsherret/ts-morph/issues/840) - Correctly add name to class without name and with extends or implements. ([ed764a7](https://github.com/dsherret/ts-morph/commit/ed764a7))


### Features

* Add quotations around enum members with invalid names ([#839](https://github.com/dsherret/ts-morph/issues/839)) ([affc253](https://github.com/dsherret/ts-morph/commit/affc253)) Thanks [@jeswr](https://github.com/jeswr)!
* Implement JSDocReadonlyTag and others ([abbf208](https://github.com/dsherret/ts-morph/commit/abbf208))



<a name="7.1.3"></a>
## [7.1.3](https://github.com/dsherret/ts-morph/compare/7.1.2...7.1.3) (2020-07-20)


### Bug Fixes

* [#835](https://github.com/dsherret/ts-morph/issues/835) - Do not create a parent directory when checking if it exists. ([698a169](https://github.com/dsherret/ts-morph/commit/698a169))


<a name="7.1.2"></a>
## [7.1.2](https://github.com/dsherret/ts-morph/compare/7.1.1...7.1.2) (2020-06-18)


### Bug Fixes

* [#827](https://github.com/dsherret/ts-morph/issues/827) - `realpathSync` should not throw ([f427e57](https://github.com/dsherret/ts-morph/commit/f427e57))



<a name="7.1.1"></a>
## [7.1.1](https://github.com/dsherret/ts-morph/compare/7.1.0...7.1.1) (2020-06-04)


### Bug Fixes

* [#823](https://github.com/dsherret/ts-morph/issues/823) - SourceFile#replaceWithText would sometimes throw when previous code had syntax errors. ([cc66fc0](https://github.com/dsherret/ts-morph/commit/cc66fc0))



<a name="7.1.0"></a>
# [7.1.0](https://github.com/dsherret/ts-morph/compare/7.0.2...7.1.0) (2020-05-16)


### Bug Fixes

* [#817](https://github.com/dsherret/ts-morph/issues/817) - Fix addJsDoc failing when there's no non-whitespace/asterisk characters in the jsdoc. ([6ba8f5a](https://github.com/dsherret/ts-morph/commit/6ba8f5a))


### Features

* [#816](https://github.com/dsherret/ts-morph/issues/816) - Update Typescript 3.9.2 ([ce8ac9c](https://github.com/dsherret/ts-morph/commit/ce8ac9c))



<a name="7.0.3"></a>
## [7.0.3](https://github.com/dsherret/ts-morph/compare/7.0.2...7.0.3) (2020-04-26)


### Bug Fixes

* [#808](https://github.com/dsherret/ts-morph/issues/808) - Unwrap would throw an error if body starts or ends with comments. ([eba6037](https://github.com/dsherret/ts-morph/commit/eba6037))



<a name="7.0.2"></a>
## [7.0.2](https://github.com/dsherret/ts-morph/compare/7.0.1...7.0.2) (2020-04-08)


### Performance Improvements

* **manipulation:** [#807](https://github.com/dsherret/ts-morph/issues/807) - Optimise getTextFromTextChanges performance ([d6f461f](https://github.com/dsherret/ts-morph/commit/d6f461f)) - Thanks [@killagu](https://github.com/killagu)!



<a name="7.0.1"></a>
## [7.0.1](https://github.com/dsherret/ts-morph/compare/7.0.0...7.0.1) (2020-03-29)


### Bug Fixes

* [#799](https://github.com/dsherret/ts-morph/issues/799) - Support renaming anonymous class declarations ([253a43f](https://github.com/dsherret/ts-morph/commit/253a43f))



<a name="7.0.0"></a>
# [7.0.0](https://github.com/dsherret/ts-morph/compare/6.0.2...7.0.0) (2020-02-23)


### Bug Fixes

* [#778](https://github.com/dsherret/ts-morph/issues/778) - Fixes error being thrown when inserting after a jsdoc and the jsdoc is the last member or statement. ([e069eff](https://github.com/dsherret/ts-morph/commit/e069eff))
* [#783](https://github.com/dsherret/ts-morph/issues/783) - Fix broken documentation links on npm. ([c997339](https://github.com/dsherret/ts-morph/commit/c997339))


### Code Refactoring

* Only support Node 10+. ([2339210](https://github.com/dsherret/ts-morph/commit/2339210))


### Features

* [#779](https://github.com/dsherret/ts-morph/issues/779) - Implement JSDocTemplateTag and JSDocThisTag. ([9bfc32e](https://github.com/dsherret/ts-morph/commit/9bfc32e))
* [#782](https://github.com/dsherret/ts-morph/issues/782) - Add `Node#getProject()` ([35f6bcf](https://github.com/dsherret/ts-morph/commit/35f6bcf))
* Support TypeScript 3.8. ([a2785b4](https://github.com/dsherret/ts-morph/commit/a2785b4))

### BREAKING CHANGES

* Only Node 10+ has full support. Some functionality might not work on older versions of Node.
* Update to TypeScript 3.8.


<a name="6.0.2"></a>
## [6.0.2](https://github.com/dsherret/ts-morph/compare/6.0.1...6.0.2) (2019-12-08)

### Bug Fixes

* Fix incorrect count when getting line count.


<a name="6.0.1"></a>
## [6.0.1](https://github.com/dsherret/ts-morph/compare/6.0.0...6.0.1) (2019-12-07)

I unpublished 6.0.0 and published this version instead.

### Bug Fixes

* `JSDocTag#getStructure()` was not including newlines at the start in the text. ([543c7e6](https://github.com/dsherret/ts-morph/commit/543c7e6))
* `Structures` should contain `JSDocTagStructure` ([f9f8bbc](https://github.com/dsherret/ts-morph/commit/f9f8bbc))
* Fix JSDoc being printed without blank lines. ([8a84ddf](https://github.com/dsherret/ts-morph/commit/8a84ddf))
* Fix JSDocTag printing an immediate text newline with a trailing whitespace. ([be44781](https://github.com/dsherret/ts-morph/commit/be44781))
* Fix JSDocTag#getStructure() not returning the whole tag text. ([c096d30](https://github.com/dsherret/ts-morph/commit/c096d30))

<a name="6.0.0"></a>
# [6.0.0](https://github.com/dsherret/ts-morph/compare/5.0.0...6.0.0) (2019-12-07)


### Bug Fixes

* **common:** Fix running in the browser. ([7d81e98](https://github.com/dsherret/ts-morph/commit/7d81e98))
* Fix bug where `Project#getRootDirectories()` might return a directory not in the project. ([e9878b1](https://github.com/dsherret/ts-morph/commit/e9878b1))
* Getting symbol exports by name should call `ts.escapeLeadingUnderscores` on the name. ([d2694ba](https://github.com/dsherret/ts-morph/commit/d2694ba))


### Code Refactoring

* [#767](https://github.com/dsherret/ts-morph/issues/767) - Rename `StructureTypeGuards` -> `Structure` ([b28ed73](https://github.com/dsherret/ts-morph/commit/b28ed73))
* `FileSystemHost#glob` is now asynchronous. A `globSync` method was added. ([942db7a](https://github.com/dsherret/ts-morph/commit/942db7a))


### Features

* [#764](https://github.com/dsherret/ts-morph/issues/764) - Prefer writing single line JS docs. Add JSDoc#isMultiLine(). ([59c8d38](https://github.com/dsherret/ts-morph/commit/59c8d38))
* **bootstrap:** Rename addSourceFiles -> addSourceFilesByPaths to match ts-morph. ([439a0d5](https://github.com/dsherret/ts-morph/commit/439a0d5))
* [#710](https://github.com/dsherret/ts-morph/issues/710) - Manipulation error now throws a custom error object. ([a8881d7](https://github.com/dsherret/ts-morph/commit/a8881d7))
* [#741](https://github.com/dsherret/ts-morph/issues/741) - `Directory#getSourceFiles` now accepts globs. ([b78cd39](https://github.com/dsherret/ts-morph/commit/b78cd39))
* [#750](https://github.com/dsherret/ts-morph/issues/750) - Creating an in-memory file system now loads the lib files by default. ([b1ff3ef](https://github.com/dsherret/ts-morph/commit/b1ff3ef))
* [#750](https://github.com/dsherret/ts-morph/issues/750) - The virtual file system host will have lib files loaded by default. ([8a8cf93](https://github.com/dsherret/ts-morph/commit/8a8cf93))
* [#760](https://github.com/dsherret/ts-morph/issues/760) - Move TypeGuards to be static members of Node (methods still exist on TypeGuards, but will be removed later). ([9b1e659](https://github.com/dsherret/ts-morph/commit/9b1e659)), closes [#728](https://github.com/dsherret/ts-morph/issues/728)
* [#763](https://github.com/dsherret/ts-morph/issues/763) - Add Directory#clear(). ([df93db3](https://github.com/dsherret/ts-morph/commit/df93db3))
* [#765](https://github.com/dsherret/ts-morph/issues/765) - Add QuestionDotTokenableNode. ([b620848](https://github.com/dsherret/ts-morph/commit/b620848))
* `SourceFile#applyTextChanges` now accepts objects of type `ts.TextChange`. ([e72c3f0](https://github.com/dsherret/ts-morph/commit/e72c3f0))
* Add `getTypeExpressionOrThrow()` to `JSDocReturnTag` and `JSDocPropertyLikeTag` ([8102360](https://github.com/dsherret/ts-morph/commit/8102360))
* Add `JSDoc#insertTags` and similar methods. ([67a2a66](https://github.com/dsherret/ts-morph/commit/67a2a66))
* Add `JSDocTag#remove()`. ([8b037aa](https://github.com/dsherret/ts-morph/commit/8b037aa))
* Add `JSDocTag#setTagName` ([688b783](https://github.com/dsherret/ts-morph/commit/688b783))
* Add JSDocTagStructure. ([aab3e9c](https://github.com/dsherret/ts-morph/commit/aab3e9c))
* Expose `InMemoryFileSystemHost`. ([2176f2c](https://github.com/dsherret/ts-morph/commit/2176f2c))
* Rename `useVirtualFileSystem` to `useInMemoryFileSystem` ([b69750c](https://github.com/dsherret/ts-morph/commit/b69750c))
* Support declare keyword on class properties. ([7a0c1ab](https://github.com/dsherret/ts-morph/commit/7a0c1ab))
* Upgrade to code-block-writer 10.1.0. ([5eaf5ff](https://github.com/dsherret/ts-morph/commit/5eaf5ff))
* Wrap `BigIntLiteral`. ([85eaa12](https://github.com/dsherret/ts-morph/commit/85eaa12))


### performance

* [#702](https://github.com/dsherret/ts-morph/issues/702) - Fix Project#addSourceFileAtPaths being needlessly slow in some scenarios. ([6db6f60](https://github.com/dsherret/ts-morph/commit/6db6f60))


### BREAKING CHANGES

* `JSDoc#setComment(...)` and `#getComment(...)` are now `setDescription(...)` and `getDescription()`. They also work according to #764.
* `StructureTypeGuards` is now `Structure`.
* PropertyDeclarationDeclaration and PropertyDeclarationStructure now can have a `declare` keyword (new in TS 3.7).
* JS docs will be written as a single line unless multi-line or starting with a newline. Additionally, getting a JS doc structure will have a newline at the start if the JS doc description is one line, but the JS doc is multi-line.
* `ProjectOptions#useVirtualFileSystem` is now `useInMemoryFileSystem`. This is a more accurate name.
* Creating a Project with `useInMemoryFileSystem: true` will now load in the lib files into the `node_modules/typescript/lib` folder.
* Due to the fix for #702, when using `Project#addSourceFileAtPaths` directories that do not have an ancestor directory with a source file included in the results will no longer be added to the project. If you want to ensure that a directory and all its subfolders are added, use `Project#addDirectoryAtPath(path, { recursive: true })`.
* `FileSystemHost#glob` is now asynchronous and `#globSync` was added.
* Renamed `Directory/Project#addExistingSourceFile` -> `addSourceFileAtPath`
* Renamed `Directory/Project#addExistingSourceFileIfExists` -> `addSourceFileAtPathIfExists`
* Renamed `Directory/Project#addExistingSourceFiles` -> `addSourceFilesAtPaths`
* Renamed `Directory/Project#addExistingDirectory` -> `addDirectoryAtPath`
* Renamed `Directory/Project#addExistingDirectoryIfExists` -> `addDirectoryAtPathIfExists`



<a name="5.0.0"></a>
# [5.0.0](https://github.com/dsherret/ts-morph/compare/4.3.3...5.0.0) (2019-11-08)


### Features

* [#733](https://github.com/dsherret/ts-morph/issues/733) - Soft rename addExistingSourceFile-like methods to addSourceFileAtPath-like. ([59fc2d5](https://github.com/dsherret/ts-morph/commit/59fc2d5)) - Thanks [@ChristianIvicevic](https://github.com/ChristianIvicevic)!
* Support TypeScript 3.7. ([d86d034](https://github.com/dsherret/ts-morph/commit/d86d034))
* TS 3.7 - Add TypeChecker#getTypeArguments and use that in Type#getTypeArguments. ([616ea3e](https://github.com/dsherret/ts-morph/commit/616ea3e))
* Update implementation for [#733](https://github.com/dsherret/ts-morph/issues/733). ([3613233](https://github.com/dsherret/ts-morph/commit/3613233))


### BREAKING CHANGES

* TypePredicateNode#getTypeNode() now possible returns undefined.
* Recommended to use the new `Project#addSourceFileAtPath(path)` methods instead of the ones like `Project#addExistingSourceFile(path)`. The old way will be deprecated in Version 6.
* TypeScript 3.7.x support only.


<a name="4.3.3"></a>
## [4.3.3](https://github.com/dsherret/ts-morph/compare/4.3.2...4.3.3) (2019-11-07)


### Bug Fixes

* Restrict 4.3 version of library to TS < 3.7 ([8ad2d5c](https://github.com/dsherret/ts-morph/commit/8ad2d5c))



<a name="4.3.2"></a>
## [4.3.2](https://github.com/dsherret/ts-morph/compare/4.3.1...4.3.2) (2019-10-22)


### Bug Fixes

* [#745](https://github.com/dsherret/ts-morph/issues/745) - Inserting a member when a comment was the last member would throw. ([d83c031](https://github.com/dsherret/ts-morph/commit/d83c031))



<a name="4.3.0"></a>
# [4.3.0](https://github.com/dsherret/ts-morph/compare/4.2.0...4.3.0) (2019-10-17)


### Bug Fixes

* [#735](https://github.com/dsherret/ts-morph/issues/735) - An unwrappable node would throw an error on unwrap if it had a leading comment. ([2cc4796](https://github.com/dsherret/ts-morph/commit/2cc4796))


### Features

* Add `Node#getWidth(true)` for including js docs in the width (similar to `Node#getStart(true)` in the compiler api). ([03dda0b](https://github.com/dsherret/ts-morph/commit/03dda0b))



<a name="4.2.0"></a>
# [4.2.0](https://github.com/dsherret/ts-morph/compare/4.1.1...4.2.0) (2019-10-05)


### Bug Fixes

* Fix abstract keyword accidentally being printed before scope. ([c7734dc](https://github.com/dsherret/ts-morph/commit/c7734dc))
* Fix message for Type#getDefaultOrThrow() ([ed1ced7](https://github.com/dsherret/ts-morph/commit/ed1ced7))


### Features

* [#655](https://github.com/dsherret/ts-morph/issues/655) - ExpressionNode - Add `getExpressionIfKind` methods. ([332fb7e](https://github.com/dsherret/ts-morph/commit/332fb7e))
* [#707](https://github.com/dsherret/ts-morph/issues/707) - Add `useTrailingCommas` manipulation setting option. ([938c05c](https://github.com/dsherret/ts-morph/commit/938c05c))
* [#712](https://github.com/dsherret/ts-morph/issues/712) - Add getParentIf and getParentIfOrThrow ([9e037b6](https://github.com/dsherret/ts-morph/commit/9e037b6)) ([@HoldYourWaffle](https://github.com/HoldYourWaffle))
* [#717](https://github.com/dsherret/ts-morph/issues/717) - Update `forgetNodesCreatedInBlock` to allow returning a value. ([fda5970](https://github.com/dsherret/ts-morph/commit/fda5970))
* [#722](https://github.com/dsherret/ts-morph/issues/722) - Wrap TypePredicateNode. ([9af7b34](https://github.com/dsherret/ts-morph/commit/9af7b34))
* Add `Node#forEachDescendantAsArray` ([2043ccb](https://github.com/dsherret/ts-morph/commit/2043ccb))


### Performance Improvements

* [#612](https://github.com/dsherret/ts-morph/issues/612) - insertOverloads should only print. ([8777007](https://github.com/dsherret/ts-morph/commit/8777007))



<a name="4.1.1"></a>
## [4.1.1](https://github.com/dsherret/ts-morph/compare/4.1.0...4.1.1) (2019-10-01)


### Bug Fixes

* [#708](https://github.com/dsherret/ts-morph/issues/708) - `getNonWhitespaceStart()` should not include the previous node's trailing comment. ([380c39b](https://github.com/dsherret/ts-morph/commit/380c39b))
* [#708](https://github.com/dsherret/ts-morph/issues/708) - Removing an IfStatement with a preceding else keyword will no longer error. ([f886605](https://github.com/dsherret/ts-morph/commit/f886605))



<a name="4.1.0"></a>
# [4.1.0](https://github.com/dsherret/ts-morph/compare/4.0.1...4.1.0) (2019-09-28)


### Features

* [#709](https://github.com/dsherret/ts-morph/issues/709) - Check and display syntax diagnostics when a manipulation error occurs. ([07c42b1](https://github.com/dsherret/ts-morph/commit/07c42b1))
* [#703](https://github.com/dsherret/ts-morph/issues/703) - Expand TypeGuards.is implementation to include all node kinds. ([ae82879](https://github.com/dsherret/ts-morph/commit/ae82879)) ([@lazarljubenovic](https://github.com/lazarljubenovic))



<a name="4.0.1"></a>
## [4.0.1](https://github.com/dsherret/ts-morph/compare/4.0.0...4.0.1) (2019-09-12)

Thanks to [@cancerberoSgx](https://github.com/cancerberoSgx) for discovering this was a node >= 11 issue.

### Bug Fixes

* [#685](https://github.com/dsherret/ts-morph/issues/685) - Fix `applyTextChanges` in node 11 and 12. ([e72b124](https://github.com/dsherret/ts-morph/commit/e72b124))



<a name="4.0.0"></a>
# [4.0.0](https://github.com/dsherret/ts-morph/compare/3.1.3...4.0.0) (2019-09-02)


### Bug Fixes

* [#667](https://github.com/dsherret/ts-morph/issues/667) - Fix typo in adding-source-files.md ([d635f69](https://github.com/dsherret/ts-morph/commit/d635f69))
* [#691](https://github.com/dsherret/ts-morph/issues/691) - JSDoc.getInnerText would sometimes get the wrong text if the first line content contained an asterisk. ([0661508](https://github.com/dsherret/ts-morph/commit/0661508)) - Thanks [@cancerberoSgx](https://github.com/cancerberoSgx)!
* [#692](https://github.com/dsherret/ts-morph/issues/692) - Fix getParent() for TS 3.6. ([37476f8](https://github.com/dsherret/ts-morph/commit/37476f8))


### Code Refactoring

* [#680](https://github.com/dsherret/ts-morph/issues/680) - Rename `SourceFile#getReferencedFiles()` to `getPathReferenceDirectives()`. ([578adc7](https://github.com/dsherret/ts-morph/commit/578adc7))
* `DiagnosticMessageChain#getNext()` now returns an array to match TS 3.6. ([4943196](https://github.com/dsherret/ts-morph/commit/4943196))
* Remove getEmitSkipped() from DirectoryEmitResult because it was not accurate. ([f42ff74](https://github.com/dsherret/ts-morph/commit/f42ff74))
* Rename CompilerExtendedComment to CompilerCommentNode. ([e3db1db](https://github.com/dsherret/ts-morph/commit/e3db1db))


### Features

* [#666](https://github.com/dsherret/ts-morph/issues/666) - Calling `Project#createSourceFile` with an existing file name now suggests to add the overwrite option. ([3022bb8](https://github.com/dsherret/ts-morph/commit/3022bb8))
* [#669](https://github.com/dsherret/ts-morph/issues/669) - Add past parent as second parameter to getParentWhile ([287158e](https://github.com/dsherret/ts-morph/commit/287158e)) - Thanks [@Validark](https://github.com/Validark)!
* [#672](https://github.com/dsherret/ts-morph/issues/672) - Add `Type#getPropertyOrThrow` ([c929c6c](https://github.com/dsherret/ts-morph/commit/c929c6c))
* [#680](https://github.com/dsherret/ts-morph/issues/680) - Add `SourceFile#getReferencedSourceFiles()`, `#getNodesReferencingOtherSourceFiles()`, and `#getLiteralsReferencingOtherSourceFiles()`. ([c245acc](https://github.com/dsherret/ts-morph/commit/c245acc))
* Upgrade to code-block-writer 10.0.0. ([5708865](https://github.com/dsherret/ts-morph/commit/5708865))


### Performance Improvements

* [#661](https://github.com/dsherret/ts-morph/issues/661) - Bundle scripts ([6efa96d](https://github.com/dsherret/ts-morph/commit/6efa96d))


### BREAKING CHANGES

* `SourceFile#getReferencedFiles()` is now `getPathReferenceDirectives()`.

This was done to prevent confusion with upcoming methods in #680. The name was chosen because it is similar to the methods `getTypeReferenceDirectives()` and `getLibReferenceDirectives()`.
* `CodeBlockWriter#indentBlock` is now `indent`. `withHangingIndentation` is now `hangingIndent`. `withHangingIndentationUnlessBlock` is now `hangingIndentUnlessBlock`.
* `DiagnosticMessageChain#getNext()` now returns an array to match TS 3.6.
* `DirectoryEmitResult#getEmitSkipped()` was removed. Check the output file paths and skipped file paths instead as that's more accurate.
* `CompilerExtendedComment` is now called `CompilerCommentNode`.



<a name="3.1.3"></a>
## [3.1.3](https://github.com/dsherret/ts-morph/compare/3.1.2...3.1.3) (2019-07-18)


### Bug Fixes

* [#665](https://github.com/dsherret/ts-morph/issues/665) - Getting descendants where jsx was used in a non-jsx file would throw an error. ([fa3c3bb](https://github.com/dsherret/ts-morph/commit/fa3c3bb))



<a name="3.1.2"></a>
## [3.1.2](https://github.com/dsherret/ts-morph/compare/3.1.1...3.1.2) (2019-07-16)


### Bug Fixes

* Fix windows glob filepaths problem due to upgrading to latest globby. ([e9665a0](https://github.com/dsherret/ts-morph/commit/e9665a0))
* Update to code-block-writer 9.4.1 (Removes accidentally added chai dependency). ([fd6534c](https://github.com/dsherret/ts-morph/commit/fd6534c))



<a name="3.1.1"></a>
## [3.1.1](https://github.com/dsherret/ts-morph/compare/3.0.0...3.1.1) (2019-07-13)


### Bug Fixes

* [#663](https://github.com/dsherret/ts-morph/issues/663) - Update globby to 10.0.1. ([07f3417](https://github.com/dsherret/ts-morph/commit/07f3417))


<a name="3.1.0"></a>
# [3.1.0](https://github.com/dsherret/ts-morph/compare/3.0.0...3.1.0) (2019-07-03)


### Features

* [#657](https://github.com/dsherret/ts-morph/issues/657) - Ability to specify the script kind when creating a source file. ([cb22219](https://github.com/dsherret/ts-morph/commit/cb22219))
* Add DirectoryEmitResult#getSkippedFilePaths(). ([e92ea8d](https://github.com/dsherret/ts-morph/commit/e92ea8d))


### Bug Fixes

* Emitting a source file not in the program will no longer crash.


<a name="3.0.0"></a>
# [3.0.0](https://github.com/dsherret/ts-morph/compare/2.3.0...3.0.0) (2019-06-29)


### Bug Fixes

* [#534](https://github.com/dsherret/ts-morph/issues/534) - Incorrect type resolution behaviour when providing a tsconfig.json file path and having a different current working directory. ([0ecce83](https://github.com/dsherret/ts-morph/commit/0ecce83))
* [#648](https://github.com/dsherret/ts-morph/issues/648) - Comment nodes are no longer accidentally returned in some scenarios. ([ad4c64c](https://github.com/dsherret/ts-morph/commit/ad4c64c))
* ClassLike and TypeElementMembered nodes would not get the correct "add" index when a comment member node was present. ([571ba69](https://github.com/dsherret/ts-morph/commit/571ba69))
* Comment node parser now correctly returns comments on next line after tailing comma in object literal expressions. ([966acb0](https://github.com/dsherret/ts-morph/commit/966acb0))
* Fix issues with `Node#getText({ trimLeadingIndentation: true })` indenting more than it should. ([a2210de](https://github.com/dsherret/ts-morph/commit/a2210de))
* ObjectLiteralExpression insert should insert around comment nodes. ([c3b9f28](https://github.com/dsherret/ts-morph/commit/c3b9f28)), closes [#605](https://github.com/dsherret/ts-morph/issues/605)
* Support nodes that may not have a source file (ex. `globalThis` node returned from a symbol) ([b9b0cb0](https://github.com/dsherret/ts-morph/commit/b9b0cb0))


### Code Refactoring

* [#619](https://github.com/dsherret/ts-morph/issues/619) - Rename `StructureTypeGuards` methods to remove word `Node` and `Declaration` in certain cases. ([92331e1](https://github.com/dsherret/ts-morph/commit/92331e1))
* [#633](https://github.com/dsherret/ts-morph/issues/633) - `Node#forEachChild` is now aligned with the compiler API (same with `forEachDescendant`). ([27fa43a](https://github.com/dsherret/ts-morph/commit/27fa43a))
* `SourceFile#getTypeReferenceDirectives()` and `#getReferencedFiles()` better reflects the compiler api. ([350bacb](https://github.com/dsherret/ts-morph/commit/350bacb))
* Remove `renameNode` and `renameLocations` from the language service. ([72f0e1d](https://github.com/dsherret/ts-morph/commit/72f0e1d))
* Rename `ObjectLiteralElementMemberStructures` to `ObjectLiteralExpressionPropertyStructures`. ([98f00d2](https://github.com/dsherret/ts-morph/commit/98f00d2))


### Features

* [#310](https://github.com/dsherret/ts-morph/issues/310) - Add `Symbol#getExportSymbol` and `TypeChecker#getExportSymbolOfSymbol`. ([5fce598](https://github.com/dsherret/ts-morph/commit/5fce598))
* [#561](https://github.com/dsherret/ts-morph/issues/561) - Add methods `Node#getLocals`, `#getLocalByName`, `#getLocalByNameOrThrow` ([c343de3](https://github.com/dsherret/ts-morph/commit/c343de3))
* [#605](https://github.com/dsherret/ts-morph/issues/605) - Add ability to insert comments on enum declarations. ([0420ae1](https://github.com/dsherret/ts-morph/commit/0420ae1))
* [#605](https://github.com/dsherret/ts-morph/issues/605) - Add insertMember-like methods to `ClassLikeDeclarationBase`. ([f55850b](https://github.com/dsherret/ts-morph/commit/f55850b))
* [#605](https://github.com/dsherret/ts-morph/issues/605) - Add insertMember-like methods to `TypeElementMemberedNode`. ([93a070d](https://github.com/dsherret/ts-morph/commit/93a070d))
* [#605](https://github.com/dsherret/ts-morph/issues/605) - ObjectLiteralExpression#insertProperties and similar methods. ([be0f046](https://github.com/dsherret/ts-morph/commit/be0f046))
* [#625](https://github.com/dsherret/ts-morph/issues/625) - Add `writer.withHangingIndent(() => {})`. Also better hanging indent printing ([a544e55](https://github.com/dsherret/ts-morph/commit/a544e55)), closes [#616](https://github.com/dsherret/ts-morph/issues/616)
* Add `Writers` alias for `WriterFunctions`. ([79c6694](https://github.com/dsherret/ts-morph/commit/79c6694))
* [#636](https://github.com/dsherret/ts-morph/issues/636) - Writers.returnStatement should do hanging indent in certain cases. ([db6602d](https://github.com/dsherret/ts-morph/commit/db6602d))
* [#638](https://github.com/dsherret/ts-morph/issues/638) - RenameLocation - Support `prefixText` and `suffixText` when renaming. ([9326100](https://github.com/dsherret/ts-morph/commit/9326100))
* `RenameLocation` - Add `getPrefixText()` and `getSuffixText()` ([3cb7a7f](https://github.com/dsherret/ts-morph/commit/3cb7a7f))
* Add `Node#getSymbolsInScope(meaning)` and `TypeChecker#getSymbolsInScope(node, meaning)`. ([25ab43d](https://github.com/dsherret/ts-morph/commit/25ab43d))
* Add TypeGuards.isCommentNode. ([89125a2](https://github.com/dsherret/ts-morph/commit/89125a2))
* Add WriterFunctions.assertion. ([37c875e](https://github.com/dsherret/ts-morph/commit/37c875e))
* Smart comma insertion when printing comma separated values with comments. ([ae62b07](https://github.com/dsherret/ts-morph/commit/ae62b07))
* Upgrade to code-block-writer 9.4.0.


### Performance Improvements

* [#615](https://github.com/dsherret/ts-morph/issues/615) - Remove some internal regular expressions. ([cfce40b](https://github.com/dsherret/ts-morph/commit/cfce40b))
* Improve performance of `SourceFile#indent()` and `deindent()`. ([17eefea](https://github.com/dsherret/ts-morph/commit/17eefea))


### BREAKING CHANGES

* `renameNode` and `renameLocations` are removed from the language service. To be consistent, the language service should not have methods that manipulate nodes.
* `SourceFile#getTypeReferenceDirectives()` and `#getReferencedFiles()` now return the objects similar to what the compiler api returns.
* `Node#forEachChild` is now aligned with the compiler API (same with `forEachDescendant`). These methods now stop when a value is returned in a callback and they will return the returned value.
* The `ObjectLiteralElementMemberStructures` alias is now called `ObjectLiteralExpressionPropertyStructures`. This is a more correct name as an object literal expression has "properties" rather than "members" in the compiler api.
* Renamed `StructureTypeGuards` methods to remove word `Node` and `Declaration` in certain cases.



<a name="2.3.0"></a>
# [2.3.0](https://github.com/dsherret/ts-morph/compare/2.2.0...2.3.0) (2019-05-30)

Thanks to [@marikaner](https://github.com/marikaner) for implementing the feature in this release!

### Features

* [#635](https://github.com/dsherret/ts-morph/issues/635) - Add `WriterFunctions.returnStatement` ([10e8be1](https://github.com/dsherret/ts-morph/commit/10e8be1))



<a name="2.2.0"></a>
# [2.2.0](https://github.com/dsherret/ts-morph/compare/2.1.2...2.2.0) (2019-05-25)


### Features

* [#628](https://github.com/dsherret/ts-morph/issues/628) - Custom module and type reference directive resolution ([c38c77f](https://github.com/dsherret/ts-morph/commit/c38c77f)) - Thanks [@DanTsk](https://github.com/DanTsk)!
* Add `Project#getModuleResolutionHost()` ([9085100](https://github.com/dsherret/ts-morph/commit/9085100))



<a name="2.1.2"></a>
## [2.1.2](https://github.com/dsherret/ts-morph/compare/2.1.1...2.1.2) (2019-05-20)


### Bug Fixes

* ObjectLiteralExpression methods would not get the correct "add" index when a comment member node was present. ([23f9276](https://github.com/dsherret/ts-morph/commit/23f9276))



<a name="2.1.1"></a>
## [2.1.1](https://github.com/dsherret/ts-morph/compare/2.1.0...2.1.1) (2019-05-20)


### Bug Fixes

* ClassLike and TypeElementMembered nodes would not get the correct "add" index when a comment member node was present. ([af41a29](https://github.com/dsherret/ts-morph/commit/af41a29))



<a name="2.1.0"></a>
# [2.1.0](https://github.com/dsherret/ts-morph/compare/2.0.0...2.1.0) (2019-04-29)


### Bug Fixes

* `TypeParameterDeclaration#getStructure()` should trim leading indentation on contraint and default. ([ec971ce](https://github.com/dsherret/ts-morph/commit/ec971ce))
* Mixin type guards should maintain the passed in type. ([616c4cc](https://github.com/dsherret/ts-morph/commit/616c4cc))


### Features

* [#567](https://github.com/dsherret/ts-morph/issues/567) - Update `#getStatement()` to work with type guards. ([02c8d89](https://github.com/dsherret/ts-morph/commit/02c8d89))
* [#614](https://github.com/dsherret/ts-morph/issues/614)  - Add forEachStructureChild ([f8b0f6d](https://github.com/dsherret/ts-morph/commit/f8b0f6d))
* Add `StructureTypeGuards`. ([6138472](https://github.com/dsherret/ts-morph/commit/6138472))
* Wrap `ConditionalTypeNode`. ([5e3e74c](https://github.com/dsherret/ts-morph/commit/5e3e74c))
* Wrap `InferTypeNode`. ([ec4b3f2](https://github.com/dsherret/ts-morph/commit/ec4b3f2))
* Wrap `ThisTypeNode`. ([6655c51](https://github.com/dsherret/ts-morph/commit/6655c51))


### Performance Improvements

* Upgrade to code-block-writer 8.0.0. ([218442b](https://github.com/dsherret/ts-morph/commit/218442b))



<a name="2.0.0"></a>
# [2.0.0](https://github.com/dsherret/ts-morph/compare/1.3.2...2.0.0) (2019-04-20)


### Bug Fixes

* The code writer did not handle escaping string chars in strings. ([a87850e](https://github.com/dsherret/ts-morph/commit/a87850e))
* `Node#getDescendantStatements()` is now properly typed as possibly returning an `Expression`. ([9d26400](https://github.com/dsherret/ts-morph/commit/9d26400))
* `ReturnTypedNode` and `TypedNode`'s `#getStructure()` should return the type and return type text without leading indentation. ([4d95e64](https://github.com/dsherret/ts-morph/commit/4d95e64))
* DefinitionInfo.getDeclarationNode() should return a source file when the kind is "module" and width equal to the source file. ([967206f](https://github.com/dsherret/ts-morph/commit/967206f))
* Do not add trailing whitespace when a jsdoc's description includes a blank line. ([cf314da](https://github.com/dsherret/ts-morph/commit/cf314da))
* Fix removing class elements on object literal expressions. ([4e1464e](https://github.com/dsherret/ts-morph/commit/4e1464e))
* Getting/inserting statements on a ModuleBlock was throwing an error. ([2b8adad](https://github.com/dsherret/ts-morph/commit/2b8adad))
* `isOverload()` should return `true` for abstract methods. ([558cdd1](https://github.com/dsherret/ts-morph/commit/558cdd1))


### Chores

* `EnumMember#getStructure()` no longer returns `#value` and will only return `#initializer`. ([ed25348](https://github.com/dsherret/ts-morph/commit/ed25348))


### Code Refactoring

* FileSystemHost.isCaseSensitive() is now required in implementations. ([015a124](https://github.com/dsherret/ts-morph/commit/015a124))
* InitializerGetExpressionableNode is now InitializerExpressionGetableNode for consistency. ([27c25c9](https://github.com/dsherret/ts-morph/commit/27c25c9))
* Remove `VariableDeclarationListStructure` and `VariableDeclarationList#set` and `#getStructure` ([e6953ed](https://github.com/dsherret/ts-morph/commit/e6953ed))
* Remove InitializerSetExpressionableNode. ([990c3c1](https://github.com/dsherret/ts-morph/commit/990c3c1))
* Removed default export from library. ([f127cf4](https://github.com/dsherret/ts-morph/commit/f127cf4))
* Renamed `Type#getArrayType()` to `Type#getArrayElementType()`. ([56b4935](https://github.com/dsherret/ts-morph/commit/56b4935))


### Features

* [#470](https://github.com/dsherret/ts-morph/issues/470) - Node - Ability to get text without leading indentation. ([cd380fa](https://github.com/dsherret/ts-morph/commit/cd380fa))
* [#514](https://github.com/dsherret/ts-morph/issues/514) - Add Node#forEachChildAsArray() ([ba4cd7a](https://github.com/dsherret/ts-morph/commit/ba4cd7a))
* [#563](https://github.com/dsherret/ts-morph/issues/563) - ParameterDeclaration now implements BindingNamedNode instead of DeclarationNamedNode. ([debd09b](https://github.com/dsherret/ts-morph/commit/debd09b))
* [#573](https://github.com/dsherret/ts-morph/issues/573) - ModuledNode#getExportedDeclarations() now returns a map. ([752aaf1](https://github.com/dsherret/ts-morph/commit/752aaf1))
* [#575](https://github.com/dsherret/ts-morph/issues/575) - Extended comments ([a9cc491](https://github.com/dsherret/ts-morph/commit/a9cc491))
* [#581](https://github.com/dsherret/ts-morph/issues/581) - TraversalControl - Add ability to return a value. ([d072b63](https://github.com/dsherret/ts-morph/commit/d072b63))
* [#587](https://github.com/dsherret/ts-morph/issues/587) - SourceFile#getLineAndColumnAtPos ([b987657](https://github.com/dsherret/ts-morph/commit/b987657)) - Thanks [@cancerberoSgx](https://github.com/cancerberoSgx)!
* [#588](https://github.com/dsherret/ts-morph/issues/588) - Move `ChildOrderableNode` to `Statement`. ([b5ff9ad](https://github.com/dsherret/ts-morph/commit/b5ff9ad))
* [#595](https://github.com/dsherret/ts-morph/issues/595) - Add SourceFile#fixUnusedIdentifiers ([e4b1b64](https://github.com/dsherret/ts-morph/commit/e4b1b64)) - [@cancerberoSgx](https://github.com/cancerberoSgx)
* [#596](https://github.com/dsherret/ts-morph/issues/596) - Add `CombinedCodeAction#applyChanges()` ([2566d53](https://github.com/dsherret/ts-morph/commit/2566d53))
* [#601](https://github.com/dsherret/ts-morph/issues/601) - Add `RefactorEditInfo#applyChanges()` ([ca0ca8c](https://github.com/dsherret/ts-morph/commit/ca0ca8c)) - [@cancerberoSgx](https://github.com/cancerberoSgx)
* [#603](https://github.com/dsherret/ts-morph/issues/603) - Make `emit` async and add new `emitSync` ([8a8c1c7](https://github.com/dsherret/ts-morph/commit/8a8c1c7))
* [#606](https://github.com/dsherret/ts-morph/issues/606) - `Symbol#getXByName`-like methods are now `Symbol#getX`. ([08f0710](https://github.com/dsherret/ts-morph/commit/08f0710))
* `#addStatements`/`#insertStatements` now also accepts an array of strings or writer functions. ([d1c361a](https://github.com/dsherret/ts-morph/commit/d1c361a))
* Ability to add/insert statement structures. ([faaa2cd](https://github.com/dsherret/ts-morph/commit/faaa2cd))
* Add `Type#getArrayElementTypeOrThrow()` ([cfd420e](https://github.com/dsherret/ts-morph/commit/cfd420e))
* Add ClassMemberStructures, InterfaceMemberStructures, and Structures type aliases. ([3af3d32](https://github.com/dsherret/ts-morph/commit/3af3d32))
* Add ObjectLiteralElement. ([a40a46d](https://github.com/dsherret/ts-morph/commit/a40a46d))
* getName() should always just return the name node text. ([968c13c](https://github.com/dsherret/ts-morph/commit/968c13c))
* Removed `Project#applyFileTextChanges()`. Added `FileTextChanges#applyChanges()`. ([4c62acb](https://github.com/dsherret/ts-morph/commit/4c62acb))
* Replace `StatementedNode` with new `.statements` property / Add trivia properties to structures ([5f4943b](https://github.com/dsherret/ts-morph/commit/5f4943b))
* Wrap ClassElement. ([73ecfb1](https://github.com/dsherret/ts-morph/commit/73ecfb1))


### reactor

* [#574](https://github.com/dsherret/ts-morph/issues/574) - Target ES2015. ([1e56a01](https://github.com/dsherret/ts-morph/commit/1e56a01))


### BREAKING CHANGES

* The default export was removed. Use the named `Project` export from now on.
* ModuledNode#getExportedDeclarations() now returns a map with a key as the export name and the value as an array of declarations that are exported.
* * Removed `BodyableNodeStructure`, `BodiedNodeStructure`, `ModuledNodeStructure`.
* Removed `.bodyText`, `.classes`, `.enums` properties on structures. Replaced with `.statements` property.
* Comments are parsed as children in certain scenarios. See #575 for more details.
* `Type#getArrayType()` is now `Type#getArrayElementType()`. This was renamed to better reflect what the method does.
* * ParameterDeclaration now implements BindingNamedNode instead of DeclarationNamedNode.
* `EnumMember#getStructure()` no longer returns the `#value` and will only return `#initializer`. `#value` should be seen as more of a convenience property for setting the initializer.
* `Symbol#getXByName`-like methods were renamed to `Symbol#getX`.
* `Project#applyFileTextChanges()` has moved to `FileTextChanges#applyChanges()`.
* `SourceFile#getLineNumberAtPos` is now `SourceFile#getLineAndColumnAtPos`
* JsxText#containsOnlyWhiteSpaces() is now #containsOnlyTriviaWhiteSpaces(). `FileSystemHost` requires `realpathSync`.
* Removed `VariableDeclarationListStructure` and `VariableDeclarationList#set` and `#getStructure`. This was done to simplify the structures.
* The library now targets ES2015.
* `JsxAttributeStructure` and `JsxSpreadAttributeStructure` are now differentiated based on their `.kind` property.
* `JsxElementStructure` and `JsxSelfClosingElementStructure` are now differentiated based on their `.kind` property.
* FileSystemHost.isCaseSensitive() is now required in implementations.
* Removed DeclarationNamedNode.
* InitializerSetExpressionableNode was removed and merged with InitializerExpressionableNode.
* InitializerGetExpressionableNode was renamed to InitializerExpressionGetableNode.
* getName() always returns the name node text and now never throws.



<a name="1.3.2"></a>
## [1.3.2](https://github.com/dsherret/ts-morph/compare/1.3.1...1.3.2) (2019-03-30)


### Bug Fixes

* [#591](https://github.com/dsherret/ts-morph/issues/591) - Limit to TS < 3.4 for ts-morph version 1 ([f20e473](https://github.com/dsherret/ts-morph/commit/f20e473))



<a name="1.3.1"></a>
## [1.3.1](https://github.com/dsherret/ts-morph/compare/1.3.0...1.3.1) (2019-03-17)


### Bug Fixes

* Depend on a specific version of code-block-writer. ([ccfe90e](https://github.com/dsherret/ts-morph/commit/ccfe90e))



<a name="1.3.0"></a>
# [1.3.0](https://github.com/dsherret/ts-morph/compare/1.2.0...1.3.0) (2019-03-03)


### Bug Fixes

* [#394](https://github.com/dsherret/ts-morph/issues/394) - Handle inconsistent file path casings on case insensitive file systems. ([f7f6a3c](https://github.com/dsherret/ts-morph/commit/f7f6a3c))
* [#557](https://github.com/dsherret/ts-morph/issues/557) - ExportableNode#isNamedExport() should work when named export is done via export statement. ([7e18296](https://github.com/dsherret/ts-morph/commit/7e18296))
* [#560](https://github.com/dsherret/ts-morph/issues/560) - Type#isEnum() and isEnumLiteral() would not always return correct values. ([98c82bc](https://github.com/dsherret/ts-morph/commit/98c82bc))


### Features

* [#553](https://github.com/dsherret/ts-morph/issues/553) - VariableDeclaration now has read exportable methods like isDefaultExport(). ([0991e96](https://github.com/dsherret/ts-morph/commit/0991e96))
* Add VariableDeclaration#getVariableStatement() ([bba33ee](https://github.com/dsherret/ts-morph/commit/bba33ee))



<a name="1.2.0"></a>
# [1.2.0](https://github.com/dsherret/ts-morph/compare/1.1.0...1.2.0) (2019-02-21)


Thanks to [@Pineapples](https://github.com/Pineapples) and [@schiller-manuel](https://github.com/schiller-manuel) for their contributions for this release!

### Bug Fixes

* [#548](https://github.com/dsherret/ts-morph/issues/548) - Getting JS doc descendants by kind should find nodes. ([2fd7cac](https://github.com/dsherret/ts-morph/commit/2fd7cac))


### Features

* [#535](https://github.com/dsherret/ts-morph/issues/535) - Add getTypeExpression() to JSDocReturnTag and JSDocTypeTag ([61b71b3](https://github.com/dsherret/ts-morph/commit/61b71b3)) ([@Pineapples](https://github.com/Pineapples))
* [#538](https://github.com/dsherret/ts-morph/issues/538) - Add Type#isAny() ([1d3c2bb](https://github.com/dsherret/ts-morph/commit/1d3c2bb)) ([@schiller-manuel](https://github.com/schiller-manuel))
* [#541](https://github.com/dsherret/ts-morph/issues/541) - Add TypeChecker#getResolvedSignature() ([cf5104d](https://github.com/dsherret/ts-morph/commit/cf5104d)) [@schiller-manuel](https://github.com/schiller-manuel)
* [#543](https://github.com/dsherret/ts-morph/issues/543) - Wrap IndexedAccessTypeNode. ([a1d5696](https://github.com/dsherret/ts-morph/commit/a1d5696))
* [#547](https://github.com/dsherret/ts-morph/issues/547) - Wrap JSDocSignature and JSDocType. ([9e1b0b2](https://github.com/dsherret/ts-morph/commit/9e1b0b2))
* [#542](https://github.com/dsherret/ts-morph/issues/542) - Add Signature#getDeclaration(). ([d2bc498](https://github.com/dsherret/ts-morph/commit/d2bc498)) ([@schiller-manuel](https://github.com/schiller-manuel))
* Add aliases CallLikeExpression and JsxOpeningLikeElement. ([030c6df](https://github.com/dsherret/ts-morph/commit/030c6df))
* Add Type#isUnknown() ([30bb042](https://github.com/dsherret/ts-morph/commit/30bb042))
* Add WriterFunctions - objectType, unionType, intersectionType ([d10877f](https://github.com/dsherret/ts-morph/commit/d10877f))
* Wrap JSDocFunctionType. ([8965da3](https://github.com/dsherret/ts-morph/commit/8965da3))



<a name="1.1.0"></a>
# [1.1.0](https://github.com/dsherret/ts-morph/compare/1.0.0...1.1.0) (2019-02-14)

Thanks to [@Pineapples](https://github.com/Pineapples) for implementing these features!

### Features

* [#530](https://github.com/dsherret/ts-morph/issues/530) - Add JSDocTypeExpression ([ddc1dd3](https://github.com/dsherret/ts-morph/commit/ddc1dd3))
* [#532](https://github.com/dsherret/ts-morph/issues/532) - Expose isBracketed on JSDocPropertyLikeTag ([1acc955](https://github.com/dsherret/ts-morph/commit/1acc955))



<a name="1.0.0"></a>
# 1.0.0 (2019-02-02)


### Features

* [#527](https://github.com/dsherret/ts-morph/issues/527) - Adding namespace with quotes defaults to ambient module. ([fadeeea](https://github.com/dsherret/ts-morph/commit/fadeeea))


### BREAKING CHANGES

* Library was renamed to ts-morph.


## ts-simple-ast [21.0.3](https://github.com/dsherret/ts-morph/compare/tsa-21.0.2...tsa-21.0.3) (2019-01-31)



## ts-simple-ast [21.0.2](https://github.com/dsherret/ts-morph/compare/tsa-21.0.1...tsa-21.0.2) (2019-01-28)


### Bug Fixes

* tsconfig.json with "include" and "rootDir" would not have files correctly resolved. ([b5b9af8](https://github.com/dsherret/ts-morph/commit/b5b9af8))



## ts-simple-ast [21.0.1](https://github.com/dsherret/ts-morph/compare/tsa-21.0.0...tsa-21.0.1) (2019-01-28)


### Bug Fixes

* Project#getSourceFileOrThrow - Improve error message when the source file can't be found. ([811ce1c](https://github.com/dsherret/ts-morph/commit/811ce1c))



# ts-simple-ast [21.0.0](https://github.com/dsherret/ts-morph/compare/tsa-20.0.0...tsa-21.0.0) (2019-01-11)


### Features

* [#176](https://github.com/dsherret/ts-morph/issues/176) - Support transformations using the compiler API (`Node#transform(...)`) ([3b39edb](https://github.com/dsherret/ts-morph/commit/3b39edb))
* [#511](https://github.com/dsherret/ts-morph/issues/511) - createSourceFile - Added ability to pass in a writer function. ([9a04103](https://github.com/dsherret/ts-morph/commit/9a04103))
* [#518](https://github.com/dsherret/ts-morph/issues/518) - Add SourceFile#fixMissingImports() ([28d12e3](https://github.com/dsherret/ts-morph/commit/28d12e3))
* [#520](https://github.com/dsherret/ts-morph/issues/520) - Search object and array binding patterns when looking for a node by a name. ([20239d7](https://github.com/dsherret/ts-morph/commit/20239d7))
* [#522](https://github.com/dsherret/ts-morph/issues/522) - Project should not return implicitly resolved files and directories in most scenarios. ([73c5a39](https://github.com/dsherret/ts-morph/commit/73c5a39))
* [#523](https://github.com/dsherret/ts-morph/issues/523) - Resolved node_module source files or directories are no longer returned from Project#getSourceFiles() and getDirectories() ([6cf2d40](https://github.com/dsherret/ts-morph/commit/6cf2d40))
* Add FileTextChanges#getSourceFile() ([85deec7](https://github.com/dsherret/ts-morph/commit/85deec7))
* Add LanguageService#getCombinedCodeFix(...) ([ef9f3a3](https://github.com/dsherret/ts-morph/commit/ef9f3a3))


### Performance Improvements

* [#498](https://github.com/dsherret/ts-morph/issues/498) - OfKind and ByKind methods should use ts.forEachChild when appropriate. ([5c249bf](https://github.com/dsherret/ts-morph/commit/5c249bf))
* Make internal Es5HashSet O(1) instead of O(n) for lookups. ([a12a92c](https://github.com/dsherret/ts-morph/commit/a12a92c))


### BREAKING CHANGES

* Source files implicitly resolved in the node_modules directory are no longer returned by `Project#getSourcesFiles()` and `getDirectories()`. Either add them to the project explicitly or navigate to them via methods like `.getSourceFile("node_modules/library/pathToFile.d.ts")` or `.getDirectory("node_modules")`.
* Implicitly resolved files and directories are no longer returned when calling `project.getSourceFiles()` or `project.getDirectories()`. They can be added by calling `project.addExistingSourceFiles(...)`-like methods or `project.addExistingDirectory(...)`. These source files and directories are still accessible when specifying their path though (ex. `project.getSourceFile("node_modules/typescript/lib/typescript.d.ts")`)
* `node.getFirstChildByKind` and `node.getChildrenOfKind` now search the parsed tree via `.forEachChild(...)` when specifying a parsed node's syntax kind. Previously it would only search the results of `node.getChildren()`.



# ts-simple-ast [20.0.0](https://github.com/dsherret/ts-morph/compare/tsa-19.1.0...tsa-20.0.0) (2018-12-08)


### Code Refactoring

* Remove JSDocTag.getAtToken(). ([20ccd0a](https://github.com/dsherret/ts-morph/commit/20ccd0a))


### Features

* [#505](https://github.com/dsherret/ts-morph/issues/505) - TypeParameteredNodeStructure - Accept strings ([a11ff0a](https://github.com/dsherret/ts-morph/commit/a11ff0a))
* Support TS 3.2. ([e800f8b](https://github.com/dsherret/ts-morph/commit/e800f8b))


### BREAKING CHANGES

* `JSDocTag.getAtToken()` was removed because `jsDocTag.atToken` no longer exists in ts 3.2.



# ts-simple-ast [19.1.0](https://github.com/dsherret/ts-morph/compare/tsa-19.0.0...tsa-19.1.0) (2018-12-04)


### Bug Fixes

* [#507](https://github.com/dsherret/ts-morph/issues/507) - CompilerNodeToWrappedType sometimes resolved to any. ([91e0e1e](https://github.com/dsherret/ts-morph/commit/91e0e1e)) - Huge thank you to [@Gerrit0](https://github.com/Gerrit0) for the help on this one.


### Features

* [#506](https://github.com/dsherret/ts-morph/issues/506) - Get variable statement by a declaration's name. ([6b94548](https://github.com/dsherret/ts-morph/commit/6b94548))
* [#508](https://github.com/dsherret/ts-morph/issues/508) - Expose Node.forgetDescendants. ([ee87eac](https://github.com/dsherret/ts-morph/commit/ee87eac))



# ts-simple-ast [19.0.0](https://github.com/dsherret/ts-morph/compare/tsa-18.1.0...tsa-19.0.0) (2018-11-14)


### Bug Fixes

* sourceFile.isFromExternalLibrary() would become out of date after a manipulation. ([43c6149](https://github.com/dsherret/ts-morph/commit/43c6149))


### Code Refactoring

* Project now accepts file system host on the options object rather than as a parameter. ([7f892fb](https://github.com/dsherret/ts-morph/commit/7f892fb))
* The `Options` interface was renamed to `ProjectOptions` ([15316a3](https://github.com/dsherret/ts-morph/commit/15316a3))


### Features

* [#492](https://github.com/dsherret/ts-morph/issues/492) - Resolve dependencies when constructing a project and providing a tsconfig. ([548ae43](https://github.com/dsherret/ts-morph/commit/548ae43))
* Add SourceFile.isInNodeModules() ([0a1817c](https://github.com/dsherret/ts-morph/commit/0a1817c))


### Performance Improvements

* Reuse the old program when creating a new one. ([6dc60f8](https://github.com/dsherret/ts-morph/commit/6dc60f8))


### BREAKING CHANGES

* The `Options` interface was renamed to `ProjectOptions`. This was so it's less ambiguous.
* The Project constructor changed to accept a file system host on the first options object parameter rather than as its own parameter.
* Referenced source files in module specifiers and references are now added to the project when constructing a project and providing a tsconfig. To revert back to the old behaviour, provide the `skipFileDependencyResolution` option and set it to true.



# ts-simple-ast [18.1.0](https://github.com/dsherret/ts-morph/compare/tsa-18.0.1...tsa-18.1.0) (2018-11-11)


### Bug Fixes

* forEachDescendant would error when the node in the callback parameter was forgotten. ([152c785](https://github.com/dsherret/ts-morph/commit/152c785))


### Features

Thanks to [@cancerberoSgx](https://github.com/cancerberoSgx) for both these features!

* [#488](https://github.com/dsherret/ts-morph/issues/488) - LanguageService - getSuggestionDiagnostics, getEditsForRefactor, getCodeFixesAtPosition ([9e42b10](https://github.com/dsherret/ts-morph/commit/9e42b10))
* [#491](https://github.com/dsherret/ts-morph/issues/491) Project - applyFileTextChanges ([4de796c](https://github.com/dsherret/ts-morph/commit/4de796c))



## ts-simple-ast [18.0.1](https://github.com/dsherret/ts-morph/compare/tsa-18.0.0...tsa-18.0.1) (2018-11-10)


### Bug Fixes

* [#493](https://github.com/dsherret/ts-morph/issues/493) - Renaming sometimes renamed at wrong text location. ([1f4316e](https://github.com/dsherret/ts-morph/commit/1f4316e))



# ts-simple-ast [18.0.0](https://github.com/dsherret/ts-morph/compare/tsa-17.1.1...tsa-18.0.0) (2018-10-28)


### Bug Fixes

* [#482](https://github.com/dsherret/ts-morph/issues/482) - Import and export declaration should not include quotes in module specifier in structure ([92c7f46](https://github.com/dsherret/ts-morph/commit/92c7f46) - [@cancerberoSgx](https://github.com/cancerberoSgx))
* [#483](https://github.com/dsherret/ts-morph/issues/483) - `getDerivedClasses()` fails when there exists an interface that extends the class ([2bbcec5](https://github.com/dsherret/ts-morph/commit/2bbcec5) - [@brianzinn](https://github.com/brianzinn))
* [#484](https://github.com/dsherret/ts-morph/issues/484) - organizeImports() would sometimes throw. ([447bcfc](https://github.com/dsherret/ts-morph/commit/447bcfc))
* ParameterDeclaration.getScope() should return public for readonly parameter properties with an implicit scope. ([c430eb4](https://github.com/dsherret/ts-morph/commit/c430eb4))


### Code Refactoring

* `JSDocTag.getName()` should be `.getTagName()` ([c362510](https://github.com/dsherret/ts-morph/commit/c362510))


### Features

* [#467](https://github.com/dsherret/ts-morph/issues/467) - Move some ClassDeclaration functionality into ClassLikeDeclarationBase. ([fdb5f42](https://github.com/dsherret/ts-morph/commit/fdb5f42))
* [#467](https://github.com/dsherret/ts-morph/issues/467) - Wrap ClassExpression. ([92f4be3](https://github.com/dsherret/ts-morph/commit/92f4be3))
* [#469](https://github.com/dsherret/ts-morph/issues/469) - ClassDeclaration - Add "Extract interface" ([8b19131](https://github.com/dsherret/ts-morph/commit/8b19131))
* [#471](https://github.com/dsherret/ts-morph/issues/471) - Add `Project.formatDiagnosticsWithColorAndContext(diagnostics)` ([3056a1e](https://github.com/dsherret/ts-morph/commit/3056a1e))
* [#472](https://github.com/dsherret/ts-morph/issues/472) - Add getBodyText() to BodiedNode and BodyableNode ([e41c278](https://github.com/dsherret/ts-morph/commit/e41c278))
* [#473](https://github.com/dsherret/ts-morph/issues/473) - MethodDeclaration should extend QuestionTokenableNode. ([674d3d2](https://github.com/dsherret/ts-morph/commit/674d3d2))
* Add `JSDocPropertyLikeTag.getName()` and `.getNameNode()` ([9804627](https://github.com/dsherret/ts-morph/commit/9804627))
* Wrap ModuleBlock. ([1507c8d](https://github.com/dsherret/ts-morph/commit/1507c8d))
* Wrap NamedImports and NamedExports. ([6a17fe8](https://github.com/dsherret/ts-morph/commit/6a17fe8))


### BREAKING CHANGES

* `JSDocTag`'s `.getName()` is now `.getTagName()`. This was necessary because `.getName()` should return a `JSDocPropertyLikeTag`'s name.



## ts-simple-ast [17.1.1](https://github.com/dsherret/ts-morph/compare/tsa-17.1.0...tsa-17.1.1) (2018-10-20)


### Bug Fixes

* [#468](https://github.com/dsherret/ts-morph/issues/468) - Removing class members should not assume it's in a class. ([2c4db99](https://github.com/dsherret/ts-morph/commit/2c4db99))



# ts-simple-ast [17.1.0](https://github.com/dsherret/ts-morph/compare/tsa-17.0.1...tsa-17.1.0) (2018-10-14)


### Features

* [#148](https://github.com/dsherret/ts-morph/issues/148), [#320](https://github.com/dsherret/ts-morph/issues/320) - Add WriterFunctions.object. ([dab4cfb](https://github.com/dsherret/ts-morph/commit/dab4cfb))
* Add `Project.getAmbientModules()`, `.getAmbientModule(name: string)`, and `.getAmbientModuleOrThrow(name: string)` ([7f89eea](https://github.com/dsherret/ts-morph/commit/7f89eea))



## ts-simple-ast [17.0.1](https://github.com/dsherret/ts-morph/compare/tsa-17.0.0...tsa-17.0.1) (2018-10-13)


### Bug Fixes

* [#464](https://github.com/dsherret/ts-morph/issues/464) - `printNode` should get the source file from the passed in node if it exists. ([3a77dbc](https://github.com/dsherret/ts-morph/commit/3a77dbc))



# ts-simple-ast [17.0.0](https://github.com/dsherret/ts-morph/compare/tsa-16.0.4...tsa-17.0.0) (2018-10-12)


### Bug Fixes

* Project.getSourceFileOrThrow() should always output the passed in string in the error message. ([c81081e](https://github.com/dsherret/ts-morph/commit/c81081e))
* Write more with hanging indents ([#461](https://github.com/dsherret/ts-morph/issues/461)) ([687e467](https://github.com/dsherret/ts-morph/commit/687e467))


### Code Refactoring

* Remove CompilerNodeBrandPropertyNamesType. ([ac0040e](https://github.com/dsherret/ts-morph/commit/ac0040e))


### Features

* [#153](https://github.com/dsherret/ts-morph/issues/153) - Ability to insert named exports and imports with a writer. ([aa5617e](https://github.com/dsherret/ts-morph/commit/aa5617e))
* [#400](https://github.com/dsherret/ts-morph/issues/400) - Symbol - Add global exports. ([2bbeff9](https://github.com/dsherret/ts-morph/commit/2bbeff9))
* [#445](https://github.com/dsherret/ts-morph/issues/445) - SourceFile, Directory - Add moveToDirectory and copyToDirectory. ([fc806da](https://github.com/dsherret/ts-morph/commit/fc806da))
* [#449](https://github.com/dsherret/ts-morph/issues/449) - Wrap ImportClause. ([c66ed65](https://github.com/dsherret/ts-morph/commit/c66ed65))
* [#454](https://github.com/dsherret/ts-morph/issues/454) - Wrap NamespaceImport. ([001e7d0](https://github.com/dsherret/ts-morph/commit/001e7d0))
* [#456](https://github.com/dsherret/ts-morph/issues/456) - Relax ts dependency to 3.0.1 and 3.0.3. ([1029f75](https://github.com/dsherret/ts-morph/commit/1029f75))
* ArrayLiteralExpression - Add ability to add elements with writer for each element. ([1f8b1cb](https://github.com/dsherret/ts-morph/commit/1f8b1cb))
* Better error message when using a forgotten node. ([762254f](https://github.com/dsherret/ts-morph/commit/762254f))
* Support TypeScript 3.1.1 and 3.1.3. ([1598b96](https://github.com/dsherret/ts-morph/commit/1598b96))


### BREAKING CHANGES

* Removed CompilerNodeBrandPropertyNamesType.
* More declarations are being written with hanging indents.



## ts-simple-ast [16.0.4](https://github.com/dsherret/ts-morph/compare/tsa-16.0.3...tsa-16.0.4) (2018-10-10)


### Bug Fixes

* Removing last modifier should not remove preceding comments. ([3aa9390](https://github.com/dsherret/ts-morph/commit/3aa9390))



## ts-simple-ast [16.0.3](https://github.com/dsherret/ts-morph/compare/tsa-16.0.2...tsa-16.0.3) (2018-10-08)


### Bug Fixes

* [#460](https://github.com/dsherret/ts-morph/issues/460) - Calling setHasDeclareKeyword on interfaces and type aliases should modify them. ([7d7c8e2](https://github.com/dsherret/ts-morph/commit/7d7c8e2))



## ts-simple-ast [16.0.2](https://github.com/dsherret/ts-morph/compare/tsa-16.0.0...tsa-16.0.2) (2018-10-01)


### Bug Fixes

* Export Project as named export to match declaration file. ([f529801](https://github.com/dsherret/ts-morph/commit/f529801))
* Fix `sourceFile.getExportedDeclarations()` returning import identifiers in some scenarios ([295ea4a](https://github.com/dsherret/ts-morph/commit/295ea4a))



## ts-simple-ast [16.0.1](https://github.com/dsherret/ts-morph/compare/tsa-16.0.0...tsa-16.0.1) (2018-09-30)


### Bug Fixes

* More robust directory creation. ([21ccc2e](https://github.com/dsherret/ts-morph/commit/21ccc2e))



# ts-simple-ast [16.0.0](https://github.com/dsherret/ts-morph/compare/tsa-15.1.0...tsa-16.0.0) (2018-09-30)


### Bug Fixes

* [#437](https://github.com/dsherret/ts-morph/issues/437) - Fix `findReferencesAsNodes` having an undefined entry when the reference is within a string literal. ([06943a9](https://github.com/dsherret/ts-morph/commit/06943a9))
* WeakCache and KeyValueCache weren't falling back to support ES5. ([eec9add](https://github.com/dsherret/ts-morph/commit/eec9add))


### Code Refactoring

* [#429](https://github.com/dsherret/ts-morph/issues/429) - IndexSignatureDeclaration - Return type should be nullable. ([bab0860](https://github.com/dsherret/ts-morph/commit/bab0860))
* [#441](https://github.com/dsherret/ts-morph/issues/441) - Make "XExtensionType" type aliases internal. ([9ad6372](https://github.com/dsherret/ts-morph/commit/9ad6372))


### Features

* [#436](https://github.com/dsherret/ts-morph/issues/436) - Add support for import and exports to NamespaceDeclaration ([65d4bf2](https://github.com/dsherret/ts-morph/commit/65d4bf2))
* [#439](https://github.com/dsherret/ts-morph/issues/439) - Improve type guards to use extension type for mixins. ([1ca6dd3](https://github.com/dsherret/ts-morph/commit/1ca6dd3))
* [#443](https://github.com/dsherret/ts-morph/issues/443) Better support for `global` namespace declarations ([d89fd96](https://github.com/dsherret/ts-morph/commit/d89fd96))
* Add `.getSignature()` method to nodes that have a return type. ([f65c529](https://github.com/dsherret/ts-morph/commit/f65c529))
* Upgrade to TypeScript 3.0.3. ([c38f5c2](https://github.com/dsherret/ts-morph/commit/c38f5c2))


### Performance Improvements

* [#435](https://github.com/dsherret/ts-morph/issues/435) - Memoize only before source file manipulation for some wrapped language service source file dependent objects. ([ad06259](https://github.com/dsherret/ts-morph/commit/ad06259))


### BREAKING CHANGES

* Upgraded to TS 3.0.3, which has some breaking changes in it from 3.0.1.
* IndexSignatureDeclaration's return type is now nullable to reflect what's done in the compiler API.
* The "XExtensionType" type aliases are now internal. They were hidden because they're not useful outside the library and only create noise in the named exports.
* `NamespaceDeclaration.setHasNamespaceKeyword` and `setHasModuleKeyword` are now `setDeclarationKind(kind: NamespaceDeclarationKind)`. `NamespaceDeclarationStructure.hasModuleKeyword` and `hasNamespaceKeyword` are now `declarationKind`.



# ts-simple-ast [15.1.0](https://github.com/dsherret/ts-morph/compare/tsa-15.0.2...tsa-15.1.0) (2018-09-24)


### Features

* [#431](https://github.com/dsherret/ts-morph/issues/431) - Allow passing in a module specifier string to .getImportDeclaration and .getExportDeclaration ([20b45d2](https://github.com/dsherret/ts-morph/commit/20b45d2))



## ts-simple-ast [15.0.2](https://github.com/dsherret/ts-morph/compare/tsa-15.0.1...tsa-15.0.2) (2018-09-23)


### Bug Fixes

* Fix node.findReferencesAsNodes() not returning references in initializers. ([cfeba04](https://github.com/dsherret/ts-morph/commit/cfeba04))



## ts-simple-ast [15.0.1](https://github.com/dsherret/ts-morph/compare/tsa-15.0.0...tsa-15.0.1) (2018-09-22)


### Bug Fixes

* Fix getting an ambient class' structure. ([48c92b5](https://github.com/dsherret/ts-morph/commit/48c92b5))
* Fix inserting get and set accessors in an ambient context. ([a282765](https://github.com/dsherret/ts-morph/commit/a282765))
* Fix printing and getting structure of FunctionDeclaration in ambient contexts. ([9940658](https://github.com/dsherret/ts-morph/commit/9940658))
* Fix some issues in generated ts definitions. ([0d2c00d](https://github.com/dsherret/ts-morph/commit/0d2c00d))
* Getting TypeAliasDeclaration structure should use the type node and not the type. ([aea96a3](https://github.com/dsherret/ts-morph/commit/aea96a3))
* IndexSignatureDeclaration.getStructure() should use the node text and not the type text. ([61f1345](https://github.com/dsherret/ts-morph/commit/61f1345))



# ts-simple-ast [15.0.0](https://github.com/dsherret/ts-morph/compare/tsa-14.4.5...tsa-15.0.0) (2018-09-22)


### Bug Fixes

* [#420](https://github.com/dsherret/ts-morph/issues/420) - Setting enum, namespace, or type alias as a default export should be done with a separate export assignment. ([e81412c](https://github.com/dsherret/ts-morph/commit/e81412c))
* [#424](https://github.com/dsherret/ts-morph/issues/424) - UTF-8 bom causes incorrect indentation to be inserted. ([c4a63a1](https://github.com/dsherret/ts-morph/commit/c4a63a1))
* ImportSpecifier and ExportSpecifier - Specifying an empty string to setAlias should not crash. ([a7beb66](https://github.com/dsherret/ts-morph/commit/a7beb66))


### Code Refactoring

* ImportDeclaration.setDefaultImport should not rename. ([f425bd8](https://github.com/dsherret/ts-morph/commit/f425bd8))
* JsxTagNamedNode.getTagName() is now getTagNameNode() for consistency. ([36d4907](https://github.com/dsherret/ts-morph/commit/36d4907))
* Remove accidentally exposed properties on errors. ([caa7e68](https://github.com/dsherret/ts-morph/commit/caa7e68))
* Remove typeParameter.getConstraintNode() and .getDefaultNode() ([e84c374](https://github.com/dsherret/ts-morph/commit/e84c374))


### Features

* [#418](https://github.com/dsherret/ts-morph/issues/418) - Add new .set methods and deprecate .fill ([da40d99](https://github.com/dsherret/ts-morph/commit/da40d99))
* [#423](https://github.com/dsherret/ts-morph/issues/423) - Add node.getText(true) for getting text with js docs. ([0522510](https://github.com/dsherret/ts-morph/commit/0522510))
* [#45](https://github.com/dsherret/ts-morph/issues/45) / [#346](https://github.com/dsherret/ts-morph/issues/346) - Add .getStructure() ([2d7351c](https://github.com/dsherret/ts-morph/commit/2d7351c)) -- Huge thanks to [@cancerberoSgx](https://github.com/cancerberoSgx) for all his help on this one!
* [#46](https://github.com/dsherret/ts-morph/issues/46) - Ability to set node from a structure using .set methods ([22d4753](https://github.com/dsherret/ts-morph/commit/22d4753))
* Add ExportAssignment.setExpression ([0c6fcf0](https://github.com/dsherret/ts-morph/commit/0c6fcf0))
* Add ExportAssignment.setIsExportEquals. ([43d3d84](https://github.com/dsherret/ts-morph/commit/43d3d84))
* Add ExportDeclaration.removeModuleSpecifier() ([b64c665](https://github.com/dsherret/ts-morph/commit/b64c665))
* Add ExportSpecifier.getName() ([b6357c6](https://github.com/dsherret/ts-morph/commit/b6357c6))
* Add ExpressionedNode.setExpression ([12e0ca7](https://github.com/dsherret/ts-morph/commit/12e0ca7))
* Add ImportDeclaration.removeDefaultImport() ([87dd9cf](https://github.com/dsherret/ts-morph/commit/87dd9cf))
* Add ImportDeclaration.renameDefaultImport. ([1ba29be](https://github.com/dsherret/ts-morph/commit/1ba29be))
* Add JsxAttribute .setInitializer & .removeInitializer ([9436954](https://github.com/dsherret/ts-morph/commit/9436954))
* Add JsxSpreadAttribute.setExpression ([532131f](https://github.com/dsherret/ts-morph/commit/532131f))
* Hide "Specific" structures in declaration file. ([db55c33](https://github.com/dsherret/ts-morph/commit/db55c33))
* ImportDeclaration.setDefaultImport should remove the default import when providing an empty string. ([f81f90a](https://github.com/dsherret/ts-morph/commit/f81f90a))
* ImportSpecifier and ExportSpecifier - .setAlias(...) does not the usages. ([5f2f7c8](https://github.com/dsherret/ts-morph/commit/5f2f7c8))
* ImportSpecifier and ExportSpecifier - Add .removeAlias(). ([b594113](https://github.com/dsherret/ts-morph/commit/b594113))
* ImportSpecifier and ExportSpecifier - Add removeAliasWithRename() ([576db34](https://github.com/dsherret/ts-morph/commit/576db34))
* ImportSpecifier and ExportSpecifier - Renamed .setAlias to .renameAlias ([0f446b6](https://github.com/dsherret/ts-morph/commit/0f446b6))


### BREAKING CHANGES

* Some properties on thrown errors were removed. See commit for details.
* TypeParameterDeclaration's getConstraintNode() and getDefaultNode() are deprecated. Use getConstraint() and getDefault().
* JsxTagNamedNode.getTagName() is now .getTagNameNode()
* ImportDeclaration.setDefaultImport no longer renames the identifier. Use `.renameDefaultImport` instead.
* .setAlias(...) does not rename the usages.
* .setAlias(...) is now .renameAlias(...).
* `.fill(...)` is now `.set(...)` and will replace existing nodes.
* Change to jsx spread attribute structure.



## ts-simple-ast [14.4.5](https://github.com/dsherret/ts-morph/compare/tsa-14.4.3...tsa-14.4.5) (2018-09-15)


### Bug Fixes

* [#421](https://github.com/dsherret/ts-morph/issues/421) - "Adding a child to an empty namespace with dot notation in the name causes brace to be lost" ([0b73d4f](https://github.com/dsherret/ts-morph/commit/0b73d4f))
* Abstract methods were incorrectly returning true for .isOverload() ([ef29ee1](https://github.com/dsherret/ts-morph/commit/ef29ee1))
* Fix crashes when dealing with statemented nodes that don't have a body. ([7a08ab1](https://github.com/dsherret/ts-morph/commit/7a08ab1))



## ts-simple-ast [14.4.4](https://github.com/dsherret/ts-morph/compare/tsa-14.4.3...tsa-14.4.4) (2018-09-15)


### Bug Fixes

* [#421](https://github.com/dsherret/ts-morph/issues/421) - "Adding a child to an empty namespace with dot notation in the name causes brace to be lost" ([0b73d4f](https://github.com/dsherret/ts-morph/commit/0b73d4f))
* Abstract methods were incorrectly returning true for .isOverload() ([ef29ee1](https://github.com/dsherret/ts-morph/commit/ef29ee1))



# ts-simple-ast [14.4.3](https://github.com/dsherret/ts-morph/compare/tsa-14.4.2...tsa-14.4.3) (2018-09-07)


### Bug Fixes

* [#414](https://github.com/dsherret/ts-morph/issues/414) - insertText() not working for namespace declaration ([ee1fa55](https://github.com/dsherret/ts-morph/commit/ee1fa55))
* [#415](https://github.com/dsherret/ts-morph/issues/415) - Fix "typeRoots" compiler option not working. ([5e4cd08](https://github.com/dsherret/ts-morph/commit/5e4cd08))



## ts-simple-ast [14.4.2](https://github.com/dsherret/ts-morph/compare/tsa-14.4.1...tsa-14.4.2) (2018-08-27)


### Bug Fixes

* [#413](https://github.com/dsherret/ts-morph/issues/413) - .addExistingSourceFiles(...) will occasionally error for certain file globs. ([15a6027](https://github.com/dsherret/ts-morph/commit/15a6027))



## ts-simple-ast [14.4.1](https://github.com/dsherret/ts-morph/compare/tsa-14.4.0...tsa-14.4.1) (2018-08-27)


### Bug Fixes

* [#410](https://github.com/dsherret/ts-morph/issues/410) - `sourceFile.getExportedDeclarations()` throws exception if file is empty ([8d563ac](https://github.com/dsherret/ts-morph/commit/8d563ac))



# ts-simple-ast [14.4.0](https://github.com/dsherret/ts-morph/compare/tsa-14.3.0...tsa-14.4.0) (2018-08-26)


### Features

* [#126](https://github.com/dsherret/ts-morph/issues/126) - Ability to emit to memory. ([4f6fb5a](https://github.com/dsherret/ts-morph/commit/4f6fb5a))
* [#409](https://github.com/dsherret/ts-morph/issues/409) - Add ability to specify custom transformers when emitting. ([644eba5](https://github.com/dsherret/ts-morph/commit/644eba5))
* Export errors. ([#402](https://github.com/dsherret/ts-morph/issues/402)) ([b719ed8](https://github.com/dsherret/ts-morph/commit/b719ed8))



# ts-simple-ast [14.3.0](https://github.com/dsherret/ts-morph/compare/tsa-14.2.1...tsa-14.3.0) (2018-08-25)


### Bug Fixes

* Use ReadonlyArray for array inputs. ([2a5ed73](https://github.com/dsherret/ts-morph/commit/2a5ed73))


### Features

* [#380](https://github.com/dsherret/ts-morph/issues/380) - Expose options to rename in comments and strings ([29592c7](https://github.com/dsherret/ts-morph/commit/29592c7))
* [#390](https://github.com/dsherret/ts-morph/issues/390) - Add Node.getFirstAncestor and getFirstAncestorOrThrow methods. ([f83be80](https://github.com/dsherret/ts-morph/commit/f83be80))
* [#406](https://github.com/dsherret/ts-morph/issues/406) - Wrap ParenthesizedTypeNode. ([9429704](https://github.com/dsherret/ts-morph/commit/9429704))
* [#74](https://github.com/dsherret/ts-morph/issues/74) - Add more "OrThrow" methods. ([2d5c94d](https://github.com/dsherret/ts-morph/commit/2d5c94d))
* Use readonly arrays for file globs ([#401](https://github.com/dsherret/ts-morph/issues/401)) ([c96d987](https://github.com/dsherret/ts-morph/commit/c96d987))

### Performance Improvements

* [#307](https://github.com/dsherret/ts-morph/issues/307) - Reduce token parsing. ([a6c4ca4](https://github.com/dsherret/ts-morph/commit/a6c4ca4))


## ts-simple-ast [14.2.1](https://github.com/dsherret/ts-morph/compare/tsa-14.2.0...tsa-14.2.1) (2018-08-25)


### Bug Fixes

* [#405](https://github.com/dsherret/ts-morph/issues/405) - "Error when renaming a file when [@types](https://github.com/types) exists" ([a63400c](https://github.com/dsherret/ts-morph/commit/a63400c))



# ts-simple-ast [14.2.0](https://github.com/dsherret/ts-morph/compare/tsa-14.1.0...tsa-14.2.0) (2018-08-22)

### Features

* Symbol - Add .getMembers(), .getMemberByName(name), and .getMemberByNameOrThrow(name). ([6fb28b4](https://github.com/dsherret/ts-morph/commit/6fb28b4))



## ts-simple-ast [14.1.1](https://github.com/dsherret/ts-morph/compare/tsa-14.1.0...tsa-14.1.1) (2018-08-22)


### Bug Fixes

* [#397](https://github.com/dsherret/ts-morph/issues/397) - Fix type.getProperties() sometimes throwing an error. ([8078772](https://github.com/dsherret/ts-morph/commit/8078772))

### Docs

* [#399](https://github.com/dsherret/ts-morph/pull/399) - Thanks to [@Gerrit0](https://github.com/Gerrit0) for making the headers links!


# ts-simple-ast [14.1.0](https://github.com/dsherret/ts-morph/compare/tsa-14.0.1...tsa-14.1.0) (2018-08-19)


### Features

* Ability to add js docs with a writer function directly from the method. ([4ad9614](https://github.com/dsherret/ts-morph/commit/4ad9614))



## ts-simple-ast [14.0.1](https://github.com/dsherret/ts-morph/compare/tsa-14.0.0...tsa-14.0.1) (2018-08-19)


### Bug Fixes

* DocumentRegistry - Ensure any file paths sent from the compiler api are normalized. ([1c06559](https://github.com/dsherret/ts-morph/commit/1c06559))



# ts-simple-ast [14.0.0](https://github.com/dsherret/ts-morph/compare/tsa-12.7.2...tsa-14.0.0) (2018-08-18)


### Bug Fixes

* [#345](https://github.com/dsherret/ts-morph/issues/345) - ArrowFunction should be a FunctionLikeDeclaration. ([b3ea86f](https://github.com/dsherret/ts-morph/commit/b3ea86f))
* BindingNamedNode should support BindingName. ([611ea99](https://github.com/dsherret/ts-morph/commit/611ea99))


### Code Refactoring

* Deprecate `project/sourceFile.getDiagnostics()` and `program.getPreEmitDiagnostics()`. ([7e1a21b](https://github.com/dsherret/ts-morph/commit/7e1a21b))


### Features

* [#381](https://github.com/dsherret/ts-morph/issues/381) - getParent() and getParentOrThrow() return the correct type based on the type of the current node. ([efa7616](https://github.com/dsherret/ts-morph/commit/efa7616))
* Add `program.getGlobalDiagnostics()`. ([a03d257](https://github.com/dsherret/ts-morph/commit/a03d257))


### Performance Improvements

* [#393](https://github.com/dsherret/ts-morph/issues/393) - Use DocumentRegistry when creating language service. ([d879071](https://github.com/dsherret/ts-morph/commit/d879071))


### BREAKING CHANGES

* `project/sourceFile.getDiagnostics()` and `program.getPreEmitDiagnostics()` no longer exist. Use `project/sourceFile.getPreEmitDiagnostics()`.
* Removed ability to set a specific target for specific source files (all files are stored in a ts.DocumentRegistry now so that's not possible).
* `BindingNamedNode` now correctly may also return a `BindingName`.



# ts-simple-ast [13.0.0](https://github.com/dsherret/ts-morph/compare/tsa-12.7.2...tsa-13.0.0) (2018-08-06)


### Bug Fixes

* [#345](https://github.com/dsherret/ts-morph/issues/345) - ArrowFunction should be a FunctionLikeDeclaration. ([b3ea86f](https://github.com/dsherret/ts-morph/commit/b3ea86f))


### Features

* [#347](https://github.com/dsherret/ts-morph/issues/347) - Add .skip() and .up() method to `forEachDescendant`. ([361bcaf](https://github.com/dsherret/ts-morph/commit/361bcaf))
* [#369](https://github.com/dsherret/ts-morph/issues/369) - FunctionDeclaration should have an optional name. ([176825d](https://github.com/dsherret/ts-morph/commit/176825d))
* [#383](https://github.com/dsherret/ts-morph/issues/383) - Update to TS 3.0 ([547eb3d](https://github.com/dsherret/ts-morph/commit/547eb3d))
* Deprecate renameName on ImportSpecifier and ExportSpecifier. ([f94eed9](https://github.com/dsherret/ts-morph/commit/f94eed9))
* Deprecated node.getStartColumn() and node.getEndColumn(). Renamed sourceFile.getColumnAtPos(pos) to getLengthFromLineStartAtPos(pos). ([d8b61b6](https://github.com/dsherret/ts-morph/commit/d8b61b6))
* Rename CompilerApiNodeBrandPropertyNamesType to CompilerNodeBrandPropertyNamesType. ([1eb6a86](https://github.com/dsherret/ts-morph/commit/1eb6a86))
* Rename sourceFile.getLineNumberFromPos(pos) to getLineNumberAtPos(pos) ([fa5849a](https://github.com/dsherret/ts-morph/commit/fa5849a))
* Renamed getAliasIdentifier() to getAliasNode() on ImportSpecifier and ExportSpecifier. ([e97de72](https://github.com/dsherret/ts-morph/commit/e97de72))


### BREAKING CHANGES

* getImplementations()[i].getNode() now returns the identifier instead of the parent node. This was based on a change in the compiler api.
* Renamed sourceFile.getLineNumberFromPos(pos) to getLineNumberAtPos(pos) for consistency.
* node.getStartColumn() and node.getEndColumn() was removed. Renamed sourceFile.getColumnAtPos(pos) to getLengthFromLineStartAtPos(pos) for correctness.
* getAliasIdentifier() on ImportSpecifier and ExportSpecifier is now getAliasNode() for consistency.
* renameName on ImportSpecifier and ExportSpecifier is now deprecated. Use `importSpecifier.getNameNode().rename(newName)`.
* CompilerApiNodeBrandPropertyNamesType is now CompilerNodeBrandPropertyNamesType for consistency.
* FunctionDeclaration now has an optional name to support cases where it does (ex. `export default function() {}`)



## ts-simple-ast [12.7.2](https://github.com/dsherret/ts-morph/compare/tsa-12.7.1...tsa-12.7.2) (2018-07-24)


### Bug Fixes

* [#374](https://github.com/dsherret/ts-morph/issues/374) - Surround parameter in parenthesis when there is none and setting its initializer, type, or adding a question token. ([847dab6](https://github.com/dsherret/ts-morph/commit/847dab6))



## ts-simple-ast [12.7.1](https://github.com/dsherret/ts-morph/compare/tsa-12.7.0...tsa-12.7.1) (2018-07-24)


### Bug Fixes

* [#373](https://github.com/dsherret/ts-morph/issues/373) - Fix setType when only a question or exclamation token exists. ([15d6a24](https://github.com/dsherret/ts-morph/commit/15d6a24))



# ts-simple-ast [12.7.0](https://github.com/dsherret/ts-morph/compare/tsa-12.6.2...tsa-12.7.0) (2018-07-18)


### Features

* [#370](https://github.com/dsherret/ts-morph/issues/370) - Add RenameableNode. ([1d18158](https://github.com/dsherret/ts-morph/commit/1d18158))



## ts-simple-ast [12.6.2](https://github.com/dsherret/ts-morph/compare/tsa-12.6.1...tsa-12.6.2) (2018-07-17)


### Bug Fixes

* [#366](https://github.com/dsherret/ts-morph/issues/366) - Should be able to add a question token to a node without a type. ([c43c1e7](https://github.com/dsherret/ts-morph/commit/c43c1e7))



## ts-simple-ast [12.6.1](https://github.com/dsherret/ts-morph/compare/tsa-12.6.0...tsa-12.6.1) (2018-07-16)


### Bug Fixes

* [#365](https://github.com/dsherret/ts-morph/issues/365) - Replacing text of an identifier deep in a property access expression would throw. ([4a7b1e2](https://github.com/dsherret/ts-morph/commit/4a7b1e2))
* [#364](https://github.com/dsherret/ts-morph/issues/364) - More browser fixes (thanks [@cancerberoSgx](https://github.com/cancerberoSgx))



# ts-simple-ast [12.6.0](https://github.com/dsherret/ts-morph/compare/tsa-12.5.3...tsa-12.6.0) (2018-07-16)


### Bug Fixes

* [#362](https://github.com/dsherret/ts-morph/issues/362) - SyntaxList.insertChildText(...) would throw when not inserting to the child syntax list. ([738fb47](https://github.com/dsherret/ts-morph/commit/738fb47))
* Should properly add statements to a case or default clause with a block. ([65d96bc](https://github.com/dsherret/ts-morph/commit/65d96bc))


### Features

* [#339](https://github.com/dsherret/ts-morph/issues/339) - Add Directory.addExistingSourceFiles(...). ([bb5cd6e](https://github.com/dsherret/ts-morph/commit/bb5cd6e))
* [#355](https://github.com/dsherret/ts-morph/issues/355) - Add `getLengthFromLineStartAtPos` to replace `getColumnAtPos` in next major. ([e82cdff](https://github.com/dsherret/ts-morph/commit/e82cdff))
* [#363](https://github.com/dsherret/ts-morph/issues/363) - Add type guard overloads to methods with a condition for a node. ([21da2fc](https://github.com/dsherret/ts-morph/commit/21da2fc))



## ts-simple-ast [12.5.4](https://github.com/dsherret/ts-morph/compare/tsa-12.5.3...tsa-12.5.4) (2018-07-14)


### Bug Fixes

* [#362](https://github.com/dsherret/ts-morph/issues/362) - SyntaxList.insertChildText(...) would throw when not inserting to the child syntax list. ([738fb47](https://github.com/dsherret/ts-morph/commit/738fb47))
* Should properly add statements to a case or default clause with a block. ([65d96bc](https://github.com/dsherret/ts-morph/commit/65d96bc))



## ts-simple-ast [12.5.3](https://github.com/dsherret/ts-morph/compare/tsa-12.5.2...tsa-12.5.3) (2018-07-12)


### Bug Fixes

* [#361](https://github.com/dsherret/ts-morph/pull/361) - Conditionally import "globby" to allow using library in browser (thanks [@cancerberoSgx](https://github.com/cancerberoSgx)!)


## ts-simple-ast [12.5.2](https://github.com/dsherret/ts-morph/compare/tsa-12.5.1...tsa-12.5.2) (2018-07-12)


### Bug Fixes

* [#359](https://github.com/dsherret/ts-morph/issues/359) - Fix problems when manipulating within forEachChild or forEachDescendant. ([bc124ed](https://github.com/dsherret/ts-morph/commit/bc124ed))



## ts-simple-ast [12.5.1](https://github.com/dsherret/ts-morph/compare/tsa-12.5.0...tsa-12.5.1) (2018-07-06)


### Bug Fixes

* [#356](https://github.com/dsherret/ts-morph/issues/356) - Setting method as abstract in structure should not write method body. ([8f70df2](https://github.com/dsherret/ts-morph/commit/8f70df2))



# ts-simple-ast [12.5.0](https://github.com/dsherret/ts-morph/compare/tsa-12.4.1...tsa-12.5.0) (2018-07-02)


### Bug Fixes

* [#354](https://github.com/dsherret/ts-morph/issues/354) - Support using ts-morph in the browser without mocking "fs" or "fs-extra" ([795fe55](https://github.com/dsherret/ts-morph/commit/795fe55))
* BooleanLiteral#setLiteralValue(value: boolean) should never return undefined. ([d1ee709](https://github.com/dsherret/ts-morph/commit/d1ee709))
* NamespaceDeclaration#getDeclarationKindKeyword should never return undefined. ([0b81c00](https://github.com/dsherret/ts-morph/commit/0b81c00))


### Features

* Add JSDocTag#getName(). ([0c868e9](https://github.com/dsherret/ts-morph/commit/0c868e9))
* Add Symbol#getAliasedSymbolOrThrow() and Symbol#getExportByNameOrThrow(name: string). ([78c7ea3](https://github.com/dsherret/ts-morph/commit/78c7ea3))



## ts-simple-ast [12.4.1](https://github.com/dsherret/ts-morph/compare/tsa-12.4.0...tsa-12.4.1) (2018-07-02)


### Bug Fixes

* [#348](https://github.com/dsherret/ts-morph/issues/348) - project.getSourceFiles() would sometimes return multiple instances of the same source file. ([8888967](https://github.com/dsherret/ts-morph/commit/8888967))
* [#352](https://github.com/dsherret/ts-morph/issues/352) - Fixed reading relative files from tsconfig.json with multiple rootDirs ([c2e948f](https://github.com/dsherret/ts-morph/commit/c2e948f)) -- Thanks [@dzinxed](https://github.com/dzinxed)!



# ts-simple-ast [12.4.0](https://github.com/dsherret/ts-morph/compare/tsa-12.3.0...tsa-12.4.0) (2018-06-10)


### Features

* [#342](https://github.com/dsherret/ts-morph/issues/342) - Finish work on removing property assignment. ([9e35623](https://github.com/dsherret/ts-morph/commit/9e35623))
* Add ability to add/insert type parameters with a default type node. ([cd05c3f](https://github.com/dsherret/ts-morph/commit/cd05c3f))
* Add SourceFile.isFromExternalLibrary ([136a2da](https://github.com/dsherret/ts-morph/commit/136a2da))
* Add Symbol.getEscapedName() ([4360bab](https://github.com/dsherret/ts-morph/commit/4360bab))
* Add TypeParameterDeclaration - getConstraintOrThrow() and getDefaultOrThrow() ([8e8166b](https://github.com/dsherret/ts-morph/commit/8e8166b))
* TypeParameterDeclaration - Add .removeDefault() and .removeConstraint() ([7a9d329](https://github.com/dsherret/ts-morph/commit/7a9d329))
* TypeParameterDeclaration - Add .setDefault(text) and .setConstraint(text) ([de9d91b](https://github.com/dsherret/ts-morph/commit/de9d91b))



# ts-simple-ast [12.3.0](https://github.com/dsherret/ts-morph/compare/tsa-12.2.0...tsa-12.3.0) (2018-06-09)


### Features

* [#342](https://github.com/dsherret/ts-morph/issues/342) - Ability to remove more object literal expression members ([e82d45f](https://github.com/dsherret/ts-morph/commit/e82d45f),
  [9e35623](https://github.com/dsherret/ts-morph/commit/9e35623)) -- Thanks [@cancerberoSgx](https://github.com/cancerberoSgx) for the help!

### Bug Fixes

* [#340](https://github.com/dsherret/ts-morph/pull/340) - Fix insert/remove support for Block ([@cancerberoSgx](https://github.com/cancerberoSgx)).

# ts-simple-ast [12.2.0](https://github.com/dsherret/ts-morph/compare/tsa-12.1.0...tsa-12.2.0) (2018-06-04)


### Features

* Add Node.getStartColumn(), Node.getEndColumn(), SourceFile.getColumnAtPos(pos). ([5119e83](https://github.com/dsherret/ts-morph/commit/5119e83))
* Add UserPreferences on sourceFile.organizeImports() ([6b0a089](https://github.com/dsherret/ts-morph/commit/6b0a089))



# ts-simple-ast [12.1.0](https://github.com/dsherret/ts-morph/compare/tsa-12.0.0...tsa-12.1.0) (2018-06-04)


### Features

* Add ImportTypeNode. ([3d0203c](https://github.com/dsherret/ts-morph/commit/3d0203c))
* ImportTypeNode - setArgument and setQualifier ([e94bbd4](https://github.com/dsherret/ts-morph/commit/e94bbd4))
* Improvements to CompilerNodeToWrappedType. ([384613a](https://github.com/dsherret/ts-morph/commit/384613a))



# ts-simple-ast [12.0.0](https://github.com/dsherret/ts-morph/compare/tsa-11.3.0...tsa-12.0.0) (2018-06-03)


### Code Refactoring

* Remove .getReferencingNodes() found on some nodes and languageService.getDefinitionReferencingNodes() ([a20cd4e](https://github.com/dsherret/ts-morph/commit/a20cd4e))


### Features

* [#302](https://github.com/dsherret/ts-morph/issues/302) - Add CompilerNodeToWrappedType. ([0ce5af5](https://github.com/dsherret/ts-morph/commit/0ce5af5))
* [#304](https://github.com/dsherret/ts-morph/issues/304) - Improve getNodeProperty by using condition types. Add CompilerNodeToWrapperMappings. ([5bd2926](https://github.com/dsherret/ts-morph/commit/5bd2926))
* [#337](https://github.com/dsherret/ts-morph/issues/337) - Add DiagnosticWithLocation. ([f1f700e](https://github.com/dsherret/ts-morph/commit/f1f700e))
* [#337](https://github.com/dsherret/ts-morph/issues/337) - Add DocumentSpan - getOriginalTextSpan and getOriginalFileName ([254bea8](https://github.com/dsherret/ts-morph/commit/254bea8))
* [#337](https://github.com/dsherret/ts-morph/issues/337) - DefinitionInfo now extends DocumentSpan as done in ts 2.9. ([c1ff983](https://github.com/dsherret/ts-morph/commit/c1ff983))
* [#338](https://github.com/dsherret/ts-morph/issues/338) - Add Diagnostic.getLineNumber() ([4cba457](https://github.com/dsherret/ts-morph/commit/4cba457))
* Add Type: isUnionOrIntersection, isClass, and isClassOrInterface. ([12c4710](https://github.com/dsherret/ts-morph/commit/12c4710))
* Add UserPreferences and new organizeImports parameter ([a7864f1](https://github.com/dsherret/ts-morph/commit/a7864f1))
* Update to TypeScript 2.9. ([da45aae](https://github.com/dsherret/ts-morph/commit/da45aae))


### BREAKING CHANGES

* `getNodeProperty` functionality requires TS 2.8 or greater due to mapped types.
* DefinitionInfo.getNode() is now DefinitionInfo.getDeclarationNode() for compatibility with DocumentSpan.
* getReferencingNodes and getDefinitionReferencingNodes are both renamed to .findReferencesAsNodes(). This is so the method is more discoverable in auto complete when looking at .findReferences().
* Renamed all Type.isXType() methods to Type.isX() to match what's done in the compiler api and to remove needless repetition in name.
* Updating to TypeScript 2.9 introduces some changes in behaviour and breaking changes in the compiler API declaration file.



# ts-simple-ast [11.3.0](https://github.com/dsherret/ts-morph/compare/tsa-11.2.2...tsa-11.3.0) (2018-06-01)


### Features

* Add .findReferencesAsNodes() to deprecate .getReferencingNodes() in next major. ([a8a731a](https://github.com/dsherret/ts-morph/commit/a8a731a))



## ts-simple-ast [11.2.2](https://github.com/dsherret/ts-morph/compare/tsa-11.2.1...tsa-11.2.2) (2018-06-01)


### Bug Fixes

* [#336](https://github.com/dsherret/ts-morph/issues/336) - Calling .remove() incorrectly removes next sibling's leading comments. ([aab1c1b](https://github.com/dsherret/ts-morph/commit/aab1c1b))
* sourceFile.getTrailingTriviaEnd() should return the end position of the source file. ([ff6b3b3](https://github.com/dsherret/ts-morph/commit/ff6b3b3))



## ts-simple-ast [11.2.1](https://github.com/dsherret/ts-morph/compare/tsa-11.2.0...tsa-11.2.1) (2018-05-28)


### Bug Fixes

* [#335](https://github.com/dsherret/ts-morph/issues/335) - addStatements would throw if the containing block was only indented a portion of an indentation level. ([c93104c](https://github.com/dsherret/ts-morph/commit/c93104c))



# ts-simple-ast [11.2.0](https://github.com/dsherret/ts-morph/compare/tsa-11.1.1...tsa-11.2.0) (2018-05-08)


### Features

* [#251](https://github.com/dsherret/ts-morph/issues/251) - Add importDeclaration.removeNamespaceImport() and .getNamespaceImportOrThrow() ([0250138](https://github.com/dsherret/ts-morph/commit/0250138))
* Add ImportDeclaration.getImportClause() and .getImportClauseOrThrow() ([8d99c27](https://github.com/dsherret/ts-morph/commit/8d99c27))
* Node.preprendWhitespace(textOrWriterFunction) and .appendWhitespace(textOrWriterFunction) ([a43cb65](https://github.com/dsherret/ts-morph/commit/a43cb65))
* Update code-block-writer version. Adds .tab(), .tabIfLastNot(), and .isLastTab(). ([903b8ac](https://github.com/dsherret/ts-morph/commit/903b8ac))



## ts-simple-ast [11.1.1](https://github.com/dsherret/ts-morph/compare/tsa-11.1.0...tsa-11.1.1) (2018-05-05)


### Bug Fixes

* [#269](https://github.com/dsherret/ts-morph/issues/269) - Support "extends" in tsconfig.json. ([4964bb7](https://github.com/dsherret/ts-morph/commit/4964bb7))



# ts-simple-ast [11.1.0](https://github.com/dsherret/ts-morph/compare/tsa-11.0.0...tsa-11.1.0) (2018-05-01)


### Features

* Ability to add/insert an argument with a writer. ([e1bcb6a](https://github.com/dsherret/ts-morph/commit/e1bcb6a))
* Ability to set a DecoratorStructure's arguments using a writer function. ([585793c](https://github.com/dsherret/ts-morph/commit/585793c))
* Ability to set a IndexSignatureDeclaration's return type using a writer function. ([0d6526d](https://github.com/dsherret/ts-morph/commit/0d6526d))
* Ability to set a JSDoc's description in a structure by using a writer. ([0250ae1](https://github.com/dsherret/ts-morph/commit/0250ae1))
* Ability to set a PropertyAssignment's initializer using a writer function. ([b633937](https://github.com/dsherret/ts-morph/commit/b633937))
* Ability to set a return type with a writer. ([3db81f8](https://github.com/dsherret/ts-morph/commit/3db81f8))
* Ability to set a SourceFileStructure's bodyText using a writer function. ([792c530](https://github.com/dsherret/ts-morph/commit/792c530))
* Ability to set a SpreadAssignmentStructure's expression using a writer function. ([e7e0158](https://github.com/dsherret/ts-morph/commit/e7e0158))
* Ability to set a type with a writer. ([5dc3565](https://github.com/dsherret/ts-morph/commit/5dc3565))



# ts-simple-ast [11.0.0](https://github.com/dsherret/ts-morph/compare/tsa-10.5.0...tsa-11.0.0) (2018-04-29)


### Bug Fixes

* [#312](https://github.com/dsherret/ts-morph/issues/312) - StatementedNode uses inconsistent source for child count. ([67a22b9](https://github.com/dsherret/ts-morph/commit/67a22b9))
* Directory.copy should not update module specifiers pointing to other files in the directory being copied. ([09244f9](https://github.com/dsherret/ts-morph/commit/09244f9))


### Chores

* Update FileSystemHost to have move and copy methods. ([4401755](https://github.com/dsherret/ts-morph/commit/4401755))
* Update to code-block-writer 7.0.0. ([7121e0d](https://github.com/dsherret/ts-morph/commit/7121e0d))


### Code Refactoring

* code-block-writer is now a named export. ([412482c](https://github.com/dsherret/ts-morph/commit/412482c))
* createDirectory will not throw if the directory exists. ([7be9dba](https://github.com/dsherret/ts-morph/commit/7be9dba))
* Remove Directory.remove() ([0ba8ba0](https://github.com/dsherret/ts-morph/commit/0ba8ba0))
* Remove getRelativePathToSourceFile and getRelativePathToSourceFileAsModuleSpecifier. ([734b7a0](https://github.com/dsherret/ts-morph/commit/734b7a0))
* Remove Identifier.getDefinitionReferencingNodes() ([2b1446a](https://github.com/dsherret/ts-morph/commit/2b1446a))
* Removed ExportAssignmentStructure.isEqualsExport ([0b098a5](https://github.com/dsherret/ts-morph/commit/0b098a5))
* Rename AddDirectoryOptions to DirectoryAddOptions ([ccd1627](https://github.com/dsherret/ts-morph/commit/ccd1627))
* Rename CreateSourceFileOptions to SourceFileCreateOptions and AddSourceFileOptions to SourceFileAddOptions. ([0a39f15](https://github.com/dsherret/ts-morph/commit/0a39f15))


### Features

* [#256](https://github.com/dsherret/ts-morph/issues/256) - Add Directory.copyImmediately. ([f2b01dc](https://github.com/dsherret/ts-morph/commit/f2b01dc))
* [#256](https://github.com/dsherret/ts-morph/issues/256) - Add Directory.move(...) ([29b776a](https://github.com/dsherret/ts-morph/commit/29b776a))
* [#256](https://github.com/dsherret/ts-morph/issues/256) - Add Directory.moveImmediately. ([255d01c](https://github.com/dsherret/ts-morph/commit/255d01c))
* [#311](https://github.com/dsherret/ts-morph/issues/311) - Allow providing a string instead of a JSDoc structure. ([a0b16e6](https://github.com/dsherret/ts-morph/commit/a0b16e6))
* [#320](https://github.com/dsherret/ts-morph/issues/320) - Add ability to set initializer in a structure with a writer function. ([20e51ed](https://github.com/dsherret/ts-morph/commit/20e51ed))
* [#324](https://github.com/dsherret/ts-morph/issues/324) - Added ClassDeclaration.insertConstructors() and addConstructors(). ([2aefd93](https://github.com/dsherret/ts-morph/commit/2aefd93))
* Ability to set an initializer's text using a writer. ([2c1a9e5](https://github.com/dsherret/ts-morph/commit/2c1a9e5))
* Add Directory.forget(). Will deprecate Directory.remove() in next major. ([f584d20](https://github.com/dsherret/ts-morph/commit/f584d20))
* ImportDeclaration.getDefaultImportOrThrow() ([499c741](https://github.com/dsherret/ts-morph/commit/499c741))
* Upgrade from TypeScript 2.8.1 to 2.8.3. ([106e17e](https://github.com/dsherret/ts-morph/commit/106e17e))


### BREAKING CHANGES

* ClassDeclarationStructure.ctor is renamed ctors. It accepts multiple constructors now. Additionally, insertConstructor and addConstructor on ClassDeclaration does not remove the existing constructor if it exists.
* Directory.copy correctly does not update module specifiers pointing to other files in the directory being copied.
* Updated to code-block-writer 7.0.0. The writer methods `newLineIfLastNotNewLine`, `blankLineIfLastNotBlankLine`, and `spaceIfLastNotSpace`, are removed. Use the shorter method names like `spaceIfLastNot`.
* AddDirectoryOptions -> DirectoryAddOptions
* CreateSourceFileOptions -> SourceFileCreateOptions, AddSourceFileOptions -> SourceFileAddOptions
* The FileSystemHost interface now has move and copy methods.
* code-block-writer is now exported as a named export from the library (`CodeBlockWriter`).
* Directory.remove() is now Directory.forget() for consistency with SourceFile.
* SourceFile.getRelativePathToSourceFile and getRelativePathToSourceFileAsModuleSpecifier is now getRelativePathTo and getRelativePathAsModuleSpecifierTo respectively.
* ExportAssignmentStructure.isEqualsExport is now isExportEquals. This was incorrectly named.
* Identifier.getDefinitionReferencingNodes() is now getReferencingNodes().
* createDirectory will not throw if the directory exists.



# ts-simple-ast [10.5.0](https://github.com/dsherret/ts-morph/compare/tsa-10.3.3...tsa-10.5.0) (2018-04-20)


### Bug Fixes

* Fix getting the relative path as a module specifier to the index file in the root directory. ([80ba49c](https://github.com/dsherret/ts-morph/commit/80ba49c))


### Features

* [#317](https://github.com/dsherret/ts-morph/issues/317) - Make Identifier a ReferenceFindableNode. ([652d00d](https://github.com/dsherret/ts-morph/commit/652d00d))
* Add `Directory.getRelativePathAsModuleSpecifierTo` and `getRelativePathTo` ([5d5fa08](https://github.com/dsherret/ts-morph/commit/5d5fa08))
* Add SourceFile.getRelativePathTo and getRelativePathAsModuleSpecifierTo. ([04f91eb](https://github.com/dsherret/ts-morph/commit/04f91eb))



# ts-simple-ast [10.4.0](https://github.com/dsherret/ts-morph/compare/tsa-10.3.3...tsa-10.4.0) (2018-04-18)


### Features

* [#317](https://github.com/dsherret/ts-morph/issues/317) - Make Identifier a ReferenceFindableNode. ([652d00d](https://github.com/dsherret/ts-morph/commit/652d00d))



## ts-simple-ast [10.3.3](https://github.com/dsherret/ts-morph/compare/tsa-10.3.2...tsa-10.3.3) (2018-04-17)


### Bug Fixes

* [#125](https://github.com/dsherret/ts-morph/issues/125) - Inserting a namespace or class into an ambient module/namespace should not write as non-ambient. ([a3c6291](https://github.com/dsherret/ts-morph/commit/a3c6291))
* [#316](https://github.com/dsherret/ts-morph/issues/316) - Getting references between source files was broken when the importHelpers compiler option was true. ([701e936](https://github.com/dsherret/ts-morph/commit/701e936))



## ts-simple-ast [10.3.2](https://github.com/dsherret/ts-morph/compare/tsa-10.3.1...tsa-10.3.2) (2018-04-15)


### Bug Fixes

* [#104](https://github.com/dsherret/ts-morph/issues/104) - Fix documentation with compile errors. ([9d16ab4](https://github.com/dsherret/ts-morph/commit/9d16ab4))
* ExportAssignmentStructure.isEqualsExport should be isExportEquals. Deprecated until next major. ([1189352](https://github.com/dsherret/ts-morph/commit/1189352))
* ExportDeclaration.addNamedExport method overload was a duplicate of the other one. ([3715875](https://github.com/dsherret/ts-morph/commit/3715875))



# ts-simple-ast [10.3.1](https://github.com/dsherret/ts-morph/compare/tsa-10.3.0...tsa-10.3.1) (2018-04-15)


### Bug Fixes

* [#308](https://github.com/dsherret/ts-morph/issues/308) - Should not insert before the BOM. ([07a2a51](https://github.com/dsherret/ts-morph/commit/07a2a51))
* [#314](https://github.com/dsherret/ts-morph/issues/314) - Fix moved source file not being marked as dirty in reference cache after move. ([91b1fbd](https://github.com/dsherret/ts-morph/commit/91b1fbd))
* Should update a module specifier to a source file that was added after the internal reference cache was filled. ([d6c02b1](https://github.com/dsherret/ts-morph/commit/d6c02b1))



# ts-simple-ast [10.3.0](https://github.com/dsherret/ts-morph/compare/tsa-10.1.0...tsa-10.3.0) (2018-04-11)


### Features

* [#306](https://github.com/dsherret/ts-morph/issues/306) - Add Node.forEachChild and Node.forEachDescendant ([9eabe57](https://github.com/dsherret/ts-morph/commit/9eabe57))



# ts-simple-ast [10.2.0](https://github.com/dsherret/ts-morph/compare/tsa-10.1.0...tsa-10.2.0) (2018-04-08)

Lots of performance improvements in this release. These performance improvements may have introduced bugs, so let me know about any issues!


### Bug Fixes

* Fix out of date TypeGuards by regenerating them. ([23eca82](https://github.com/dsherret/ts-morph/commit/23eca82))


### Features

* [#300](https://github.com/dsherret/ts-morph/issues/300) - Fix more nodes to have .findReferences() and .getReferencingNodes() ([9ae7383](https://github.com/dsherret/ts-morph/commit/9ae7383))
* TypeGuards.hasBody(node). ([4041dfd](https://github.com/dsherret/ts-morph/commit/4041dfd))



# ts-simple-ast [10.1.0](https://github.com/dsherret/ts-morph/compare/tsa-10.0.1...tsa-10.1.0) (2018-04-01)


### Bug Fixes

* [#219](https://github.com/dsherret/ts-morph/issues/219) - Removing the last statement in a default or case clause will cause a double newline. ([d46cbd0](https://github.com/dsherret/ts-morph/commit/d46cbd0))
* [#261](https://github.com/dsherret/ts-morph/issues/261) - sourceFile.getRelativePathToSourceFileAsModuleSpecifier(...) should not strip "index" file name when module resolution is classic. ([5ce71ac](https://github.com/dsherret/ts-morph/commit/5ce71ac))
* Update to code-block-writer 6.7.2. ([eb5bd38](https://github.com/dsherret/ts-morph/commit/eb5bd38))


### Features

* [#237](https://github.com/dsherret/ts-morph/issues/237) - Add node.getLeadingCommentRanges() and .getTrailingCommentRanges(). ([9678b3d](https://github.com/dsherret/ts-morph/commit/9678b3d))
* [#297](https://github.com/dsherret/ts-morph/issues/297) - Simpler findReferences() and getDefinitions() that only returns nodes. ([4048116](https://github.com/dsherret/ts-morph/commit/4048116))
* Add Node.getLeadingTriviaWidth(). ([09bdd01](https://github.com/dsherret/ts-morph/commit/09bdd01))
* Add Node.getTrailingTriviaEnd() and .getTrailingTriviaWidth() ([98cd0b0](https://github.com/dsherret/ts-morph/commit/98cd0b0))
* Add Program.getEmitModuleResolutionKind(). ([447573f](https://github.com/dsherret/ts-morph/commit/447573f))
* Add Project.createWriter(). ([914f503](https://github.com/dsherret/ts-morph/commit/914f503))



# ts-simple-ast [10.0.0](https://github.com/dsherret/ts-morph/compare/tsa-9.5.0...tsa-10.0.0) (2018-03-29)


### Bug Fixes

* Change formatting settings insertSpaceAfterSemicolonInForStatements to be true by default. ([b74dfd9](https://github.com/dsherret/ts-morph/commit/b74dfd9))
* Setting string literal value by string should escape newlines and quote chars. ([d68b6b9](https://github.com/dsherret/ts-morph/commit/d68b6b9))
* Should escape quote char in passed in string to EnumMember.setValue(...); ([7134702](https://github.com/dsherret/ts-morph/commit/7134702))
* Should write initializer if provided in EnumMemberStructure. ([35095dc](https://github.com/dsherret/ts-morph/commit/35095dc))


### Code Refactoring

* addDirectoryIfExists -> addExistingDirectoryIfExists ([6bb08cd](https://github.com/dsherret/ts-morph/commit/6bb08cd))
* Project & Directory, addSourceFileIfExists -> addExistingSourceFileIfExists. ([18caa1c](https://github.com/dsherret/ts-morph/commit/18caa1c))
* Renamed QuoteType to QuoteKind. ([964571a](https://github.com/dsherret/ts-morph/commit/964571a))


### Features

* [#154](https://github.com/dsherret/ts-morph/issues/154) - Configuration for spaces surrounding named imports and exports. ([76ce4ad](https://github.com/dsherret/ts-morph/commit/76ce4ad))
* [#268](https://github.com/dsherret/ts-morph/issues/268) - Ancestor directories are now lazily loaded. ([1169b54](https://github.com/dsherret/ts-morph/commit/1169b54))
* [#273](https://github.com/dsherret/ts-morph/issues/273) - Add overwrite option to createSourceFile. ([ddcd03e](https://github.com/dsherret/ts-morph/commit/ddcd03e))
* [#286](https://github.com/dsherret/ts-morph/issues/286) - Populate all directories as specified in tsconfig.json ([206e795](https://github.com/dsherret/ts-morph/commit/206e795))
* [#287](https://github.com/dsherret/ts-morph/issues/287) - Descendant directories are populated based on file globs passed to addExistingSourceFiles ([402d395](https://github.com/dsherret/ts-morph/commit/402d395))
* [#291](https://github.com/dsherret/ts-morph/issues/291) - Add Type: isNumberLiteral, isStringLiteral(), and isBooleanLiteral(). ([10e40cb](https://github.com/dsherret/ts-morph/commit/10e40cb))
* [#293](https://github.com/dsherret/ts-morph/issues/293) - Upgrade to TypeScript 2.8.1 ([16e5962](https://github.com/dsherret/ts-morph/commit/16e5962))
* [#294](https://github.com/dsherret/ts-morph/issues/294) - Add sourceFile.organizeImports() ([4f3b2ff](https://github.com/dsherret/ts-morph/commit/4f3b2ff))
* [#294](https://github.com/dsherret/ts-morph/issues/294) - Wrap languageService.organizeImports(...). ([154bf2e](https://github.com/dsherret/ts-morph/commit/154bf2e))
* [#295](https://github.com/dsherret/ts-morph/issues/295) - ClassDeclaration now has a nullable name. ([96b9857](https://github.com/dsherret/ts-morph/commit/96b9857))
* Add ImportDeclaration & ExportDeclaration .getModuleSpecifierValue(). ([1785054](https://github.com/dsherret/ts-morph/commit/1785054))
* Add new project.compilerOptions property that has the ability to change the compiler options. ([4da80ba](https://github.com/dsherret/ts-morph/commit/4da80ba))
* Add SourceFile.getLanguageVersion(). Language version is now specific to file. ([117433e](https://github.com/dsherret/ts-morph/commit/117433e))
* Add sourceFile.getReferencingLiteralsInOtherSourceFiles(). ([9f009cf](https://github.com/dsherret/ts-morph/commit/9f009cf))
* Add type.isEnumLiteralType() and type.isLiteral() ([56b26f8](https://github.com/dsherret/ts-morph/commit/56b26f8))
* addExistingDirectory and addDirectoryExists now has a recursive option. ([45efb2f](https://github.com/dsherret/ts-morph/commit/45efb2f))
* Rename VariableDeclarationType to VariableDeclarationKind. ([ce52ce3](https://github.com/dsherret/ts-morph/commit/ce52ce3))


### Performance Improvements

* [#283](https://github.com/dsherret/ts-morph/issues/283) - Do not temporarily wrap new tree when doing a manipulation. ([824819f](https://github.com/dsherret/ts-morph/commit/824819f))


### BREAKING CHANGES

* addDirectoryIfExists is now addExistingDirectoryIfExists for consistency with addExistingDirectory.
* `.getName()` and `.getNameNode()` on ClassDeclaration can now possibly return undefined (ex. `export default class { ... }`).
* VariableDeclarationType is now VariableDeclarationKind. .getDeclarationType() is now .getDeclarationKind()

This was done to reduce confusion with the word "Type".
* QuoteType is now QuoteKind.

This was done to make it consistent with NewLineKind.
* ScriptTarget was moved from manipulation settings to be stored exclusively in the compiler options.
* `getReferencingImportAndExportDeclarations()` was removed. Use `getReferencingNodesInOtherSourceFiles()`.
* `ImportDeclaration` & `ExportDeclaration` `.getModuleSpecifier()` now returns the StringLiteral. Use `.getModuleSpecifierValue()` for the previous behaviour.
* Project & Directory's addSourceFileIfExists is now addExistingSourceFileIfExists.

This was done for consistency with addExistingSourceFile.
* Requesting an ancestor directory will no longer return undefined if it is an ancestor of a "root" directory.



# ts-simple-ast [9.5.0](https://github.com/dsherret/ts-morph/compare/tsa-9.4.2...tsa-9.5.0) (2018-03-23)


### Features

* Add new getImportStringLiterals() method. ([a1b967f](https://github.com/dsherret/ts-morph/commit/a1b967f))



## ts-simple-ast [9.4.2](https://github.com/dsherret/ts-morph/compare/tsa-9.4.1...tsa-9.4.2) (2018-03-19)


### Bug Fixes

* Syntax kind to node mappings should include aliased kind names. ([5c7109e](https://github.com/dsherret/ts-morph/commit/5c7109e))



## ts-simple-ast [9.4.1](https://github.com/dsherret/ts-morph/compare/tsa-9.4.0...tsa-9.4.1) (2018-03-19)


### Bug Fixes

* Internally use the first name when getting the SyntaxKind name. ([cfab227](https://github.com/dsherret/ts-morph/commit/cfab227))



# ts-simple-ast [9.4.0](https://github.com/dsherret/ts-morph/compare/tsa-9.3.0...tsa-9.4.0) (2018-03-18)


### Features

* [#276](https://github.com/dsherret/ts-morph/issues/276) - Improvements to moving source files. ([dd03789](https://github.com/dsherret/ts-morph/commit/dd03789))
* [#279](https://github.com/dsherret/ts-morph/issues/279) - Add StatementedNode.getDescendantStatements(). ([3b8b093](https://github.com/dsherret/ts-morph/commit/3b8b093))
* [#279](https://github.com/dsherret/ts-morph/issues/279) - Move .getDescendantStatements() to Node and improve performance. ([e397aa2](https://github.com/dsherret/ts-morph/commit/e397aa2))
* [#280](https://github.com/dsherret/ts-morph/issues/280) - Add setLiteralValue to more literals. ([38c1570](https://github.com/dsherret/ts-morph/commit/38c1570))
* Ability to easily check if an external module reference is relative. ([f8676f0](https://github.com/dsherret/ts-morph/commit/f8676f0))
* Ability to easily get an ImportEqualsDeclaration and ExternalModuleReference's referenced source file. ([c6d7c7b](https://github.com/dsherret/ts-morph/commit/c6d7c7b))
* Add ImportEqualsDeclaration.setExternalModuleReference(...). ([e3396d3](https://github.com/dsherret/ts-morph/commit/e3396d3))
* Add StringLiteral.setLiteralValue(...). ([8d5ff33](https://github.com/dsherret/ts-morph/commit/8d5ff33))



# ts-simple-ast [9.3.0](https://github.com/dsherret/ts-morph/compare/tsa-9.1.0...tsa-9.3.0) (2018-03-17)


### Features

* [#250](https://github.com/dsherret/ts-morph/issues/250) - Accept strings for named imports and exports. ([8867b71](https://github.com/dsherret/ts-morph/commit/8867b71))
* [#278](https://github.com/dsherret/ts-morph/issues/278) - Add Type.isTupleType ([d7c3c3d](https://github.com/dsherret/ts-morph/commit/d7c3c3d))
* Add more type guards. ([4a1a92d](https://github.com/dsherret/ts-morph/commit/4a1a92d))
* Add Type.getConstraint() and getDefault(). ([8850266](https://github.com/dsherret/ts-morph/commit/8850266))
* Add Type.getTupleElements(). ([8c5dafc](https://github.com/dsherret/ts-morph/commit/8c5dafc))



# ts-simple-ast [9.2.0](https://github.com/dsherret/ts-morph/compare/tsa-9.1.0...tsa-9.2.0) (2018-03-17)


### Features

* [#240](https://github.com/dsherret/ts-morph/issues/240) - Ability to add/insert JSX attributes. ([e2b4a99](https://github.com/dsherret/ts-morph/commit/e2b4a99))
* [#240](https://github.com/dsherret/ts-morph/issues/240) - Ability to remove JSX attributes. ([1bf7642](https://github.com/dsherret/ts-morph/commit/1bf7642))
* Add getAttribute to JsxOpeningElement and JsxSelfClosingElement. ([7dbe0f7](https://github.com/dsherret/ts-morph/commit/7dbe0f7))
* Add getAttributeOrThrow for jsx nodes with attributes. ([93a0fbd](https://github.com/dsherret/ts-morph/commit/93a0fbd))
* Add type.isStringType and type.isNumberType. ([66eecde](https://github.com/dsherret/ts-morph/commit/66eecde))



# ts-simple-ast [9.1.0](https://github.com/dsherret/ts-morph/compare/tsa-9.0.1...tsa-9.1.0) (2018-03-13)


### Bug Fixes

* Project.getSourceFile - Getting a source file by relative path should work. ([d117ecc](https://github.com/dsherret/ts-morph/commit/d117ecc))


### Features

* TextInsertableNode - Add removeText() overload with no parameters. ([a4b5ef1](https://github.com/dsherret/ts-morph/commit/a4b5ef1))



## ts-simple-ast [9.0.1](https://github.com/dsherret/ts-morph/compare/tsa-9.0.0...tsa-9.0.1) (2018-03-12)


### Bug Fixes

* Fix intended method name. ([cbdee2e](https://github.com/dsherret/ts-morph/commit/cbdee2e))



# ts-simple-ast [9.0.0](https://github.com/dsherret/ts-morph/compare/tsa-8.2.4...tsa-9.0.0) (2018-03-11)


### Bug Fixes

* ExportableNode.isExported() takes into account all possible ways for a node to be exported from a file. ([ad07c33](https://github.com/dsherret/ts-morph/commit/ad07c33))
* Project.getSourceFile should normalize the passed in path. ([c765b16](https://github.com/dsherret/ts-morph/commit/c765b16))


### Code Refactoring

* Uses a WeakMap for wrapped Symbols, Types, etc. Internally created an Es5WeakMap. ([177dfe6](https://github.com/dsherret/ts-morph/commit/177dfe6))


### Features

* Align ClassDeclaration more with the compiler. ([9b64bb5](https://github.com/dsherret/ts-morph/commit/9b64bb5))


### BREAKING CHANGES

* Removed Symbol.equals(symbol). You can use === to compare symbols now.
* ClassDeclaration.getMembers() no longer returns parameter properties.



## ts-simple-ast [8.2.4](https://github.com/dsherret/ts-morph/compare/tsa-8.2.3...tsa-8.2.4) (2018-03-08)


### Bug Fixes

* [#271](https://github.com/dsherret/ts-morph/issues/271) - Fix SourceFile.move not deleting previous file on file system. ([a4dfda9](https://github.com/dsherret/ts-morph/commit/a4dfda9))



## ts-simple-ast [8.2.3](https://github.com/dsherret/ts-morph/compare/tsa-8.2.2...tsa-8.2.3) (2018-03-08)


### Bug Fixes

* [#270](https://github.com/dsherret/ts-morph/issues/270) - Fix relative path file globs not working when using .getSourceFiles(...) ([fa19352](https://github.com/dsherret/ts-morph/commit/fa19352))



## ts-simple-ast [8.2.2](https://github.com/dsherret/ts-morph/compare/tsa-8.2.1...tsa-8.2.2) (2018-03-06)


### Bug Fixes

* [#262](https://github.com/dsherret/ts-morph/issues/262) - Write public keyword when specified. ([6258c0e](https://github.com/dsherret/ts-morph/commit/6258c0e))



## ts-simple-ast [8.2.1](https://github.com/dsherret/ts-morph/compare/tsa-8.2.0...tsa-8.2.1) (2018-03-01)


### Bug Fixes

* [#265](https://github.com/dsherret/ts-morph/issues/265) - Fix error thrown getting members in class containing semicolon terminated constructor & method declarations. ([dfb979f](https://github.com/dsherret/ts-morph/commit/dfb979f))



# ts-simple-ast [8.2.0](https://github.com/dsherret/ts-morph/compare/tsa-8.1.0...tsa-8.2.0) (2018-02-28)


### Features

* Add project.manipulationSettings.getEditorSettings() (mostly used internally for the default) ([af82884](https://github.com/dsherret/ts-morph/commit/af82884))
* Add JsxElement setBodyText and setBodyTextInline. ([1420786](https://github.com/dsherret/ts-morph/commit/1420786))
* Add languageService.getIdentationAtPosition(...) ([4de5f82](https://github.com/dsherret/ts-morph/commit/4de5f82))
* Upgrade to code-block-writer 6.6.0 ([34c39a9](https://github.com/dsherret/ts-morph/commit/34c39a9))
* Uses the language service to figure out the indentation level when writing. ([76f9531](https://github.com/dsherret/ts-morph/commit/76f9531))



# ts-simple-ast [8.1.0](https://github.com/dsherret/ts-morph/compare/tsa-8.0.0...tsa-8.1.0) (2018-02-24)


### Features

* [#259](https://github.com/dsherret/ts-morph/issues/259) - Wrap TypeLiteralNode. ([d479100](https://github.com/dsherret/ts-morph/commit/d479100))
* Add support for strict property initialization (exclamation token). ([1e787f2](https://github.com/dsherret/ts-morph/commit/1e787f2))
* sourceFile.getBaseNameWithoutExtension() ([09a63d9](https://github.com/dsherret/ts-morph/commit/09a63d9))
* sourceFile.getExtension() ([3906902](https://github.com/dsherret/ts-morph/commit/3906902))



# ts-simple-ast [8.0.0](https://github.com/dsherret/ts-morph/compare/tsa-7.1.0...tsa-8.0.0) (2018-02-19)


### Bug Fixes

* Blank line would be inserted when calling an addXs method and providing an empty array in some scenarios. ([dfbf940](https://github.com/dsherret/ts-morph/commit/dfbf940))
* getRelativePathToSourceFileAsModuleSpecifier() should return `../` instead of `./../` when going back a directory. ([a7954fa](https://github.com/dsherret/ts-morph/commit/a7954fa))
* sourceFile.copy should return the current source file when copying to its own path. ([6e737e7](https://github.com/dsherret/ts-morph/commit/6e737e7))


### Code Refactoring

* **file-system:** Preparing for having the ability to queue deletions. ([83e45f0](https://github.com/dsherret/ts-morph/commit/83e45f0))


### Features

* [#199](https://github.com/dsherret/ts-morph/issues/199) - Add SourceFile.move(...), .getReferencingSourceFiles(), and .getReferencingImportAndExportDeclarations(). ([f22db6c](https://github.com/dsherret/ts-morph/commit/f22db6c))
* Deletes do not happen on the file system until `.save()` is called on the main `ast` object. ([d208cfd](https://github.com/dsherret/ts-morph/commit/d208cfd))
* ImportDeclaration and ExportDeclaration - isModuleSpecifierRelative() ([2ef3064](https://github.com/dsherret/ts-morph/commit/2ef3064))
* setModuleSpecifier accepts a source file. ([c2a4d9a](https://github.com/dsherret/ts-morph/commit/c2a4d9a))
* SourceFile - copyImmediately and moveImmediately along with sync methods. ([4183769](https://github.com/dsherret/ts-morph/commit/4183769))
* sourceFile.copy() will automatically update the new source file's import & export declarations' module specifiers if necessary. ([e48949e](https://github.com/dsherret/ts-morph/commit/e48949e))


### BREAKING CHANGES

* * project.saveUnsavedSourceFiles() is now project.save()
* Directory.saveUnsavedSourceFiles() is now Directory.save()
* **file-system:** SourceFile/Directory: delete() and deleteSync() are now deleteImmediately() and deleteImmediatelySync().



# ts-simple-ast [7.1.0](https://github.com/dsherret/ts-morph/compare/tsa-7.0.1...tsa-7.1.0) (2018-02-15)


### Bug Fixes

* Fix scenario where adding a modifier would throw when there was an jsdoc on the parent in some scenarios. ([1fbcee6](https://github.com/dsherret/ts-morph/commit/1fbcee6))
* Insert functions with a declaration keyword without a body. ([c64009d](https://github.com/dsherret/ts-morph/commit/c64009d))


### Features

* [#252](https://github.com/dsherret/ts-morph/issues/252) - Add Type.isNullable. ([f2dfd1f](https://github.com/dsherret/ts-morph/commit/f2dfd1f))
* Add functions and variables to typescript declaration file. ([451840b](https://github.com/dsherret/ts-morph/commit/451840b))
* Add ts.Node brand to prevent using ts.Nodes created outside the ts named export. ([ab7c353](https://github.com/dsherret/ts-morph/commit/ab7c353))
* BodyableNode - addBody, removeBody, hasBody ([3f4175e](https://github.com/dsherret/ts-morph/commit/3f4175e))



## ts-simple-ast [7.0.1](https://github.com/dsherret/ts-morph/compare/tsa-7.0.0...tsa-7.0.1) (2018-02-14)


### Bug Fixes

* Fix ts compiler types not being exported from declaration file. ([0755aa2](https://github.com/dsherret/ts-morph/commit/0755aa2))



# ts-simple-ast [7.0.0](https://github.com/dsherret/ts-morph/compare/tsa-6.13.0...tsa-7.0.0) (2018-02-14)


### Code Refactoring

* [#232](https://github.com/dsherret/ts-morph/issues/232) - HeritageClause: getTypes() -> getTypeNodes() ([ef5a369](https://github.com/dsherret/ts-morph/commit/ef5a369))
* ClassDeclaration & InterfaceDeclaration: getAllMembers -> getMembers ([cdb186a](https://github.com/dsherret/ts-morph/commit/cdb186a))
* getImport -> getImportDeclaration. ([acd9d70](https://github.com/dsherret/ts-morph/commit/acd9d70))
* Rename toggleDeclareKeyword to setHasDeclareKeyword for consistency. ([0cecefe](https://github.com/dsherret/ts-morph/commit/0cecefe))


### Features

* [#249](https://github.com/dsherret/ts-morph/issues/249) - Remove TypeScript compiler peer dependency. ([db9f0fc](https://github.com/dsherret/ts-morph/commit/db9f0fc))


### BREAKING CHANGES

* HeritageClause getTypes() renamed to getTypeNodes().

It was incorrectly named originally.
* ClassDeclaration & InterfaceDeclaration getAllMembers() renamed to getMembers().
* sourceFile.getImport is now getImportDeclaration for consistency.
* Access the TypeScript compiler via `import {ts} from "ts-morph";`
* NewLineKind is now the TypeScript compiler's enum.
* toggleDeclareKeyword is now setHasDeclareKeyword.



# ts-simple-ast [6.13.0](https://github.com/dsherret/ts-morph/compare/tsa-6.12.0...tsa-6.13.0) (2018-02-12)


### Bug Fixes

* Writing a statemented node would not respect the manipulation settings. ([179e327](https://github.com/dsherret/ts-morph/commit/179e327))
* Writing enum member value that's a string should be surrounded in quotes. ([d5da5b6](https://github.com/dsherret/ts-morph/commit/d5da5b6))


### Features

* [#240](https://github.com/dsherret/ts-morph/issues/240) - Wrap JSX nodes. ([aa4d70a](https://github.com/dsherret/ts-morph/commit/aa4d70a))



# ts-simple-ast [6.12.0](https://github.com/dsherret/ts-morph/compare/tsa-6.11.1...tsa-6.12.0) (2018-02-10)


### Features

* [#245](https://github.com/dsherret/ts-morph/issues/245) - IndexSignatureDeclaration - Add support for readonly keyword. ([2624f8b](https://github.com/dsherret/ts-morph/commit/2624f8b))



## ts-simple-ast [6.11.1](https://github.com/dsherret/ts-morph/compare/tsa-6.11.0...tsa-6.11.1) (2018-02-09)


### Bug Fixes

* [#244](https://github.com/dsherret/ts-morph/issues/244) - Fixes setOrder() bug where verify fails incorrectly. ([c7bec28](https://github.com/dsherret/ts-morph/commit/c7bec28))
* Fix failing ts 2.4 test for IndexSignatureDeclaration. ([654e5c2](https://github.com/dsherret/ts-morph/commit/654e5c2))



# ts-simple-ast [6.11.0](https://github.com/dsherret/ts-morph/compare/tsa-6.9.0...tsa-6.11.0) (2018-02-09)


### Features

* [#242](https://github.com/dsherret/ts-morph/issues/242) - Wrap IndexSignatureDeclaration. ([3dab39f](https://github.com/dsherret/ts-morph/commit/3dab39f))
* Wrap more type nodes. ([9211350](https://github.com/dsherret/ts-morph/commit/9211350))



# ts-simple-ast [6.10.0](https://github.com/dsherret/ts-morph/compare/tsa-6.9.0...tsa-6.10.0) (2018-02-07)


### Features

* Wrap more type nodes. ([9211350](https://github.com/dsherret/ts-morph/commit/9211350))



# ts-simple-ast [6.9.0](https://github.com/dsherret/ts-morph/compare/tsa-6.8.0...tsa-6.9.0) (2018-02-04)


### Bug Fixes

* [#239](https://github.com/dsherret/ts-morph/issues/239) - Fix JSDoc.getInnerText() stripping leading spaces. ([b9c56de](https://github.com/dsherret/ts-morph/commit/b9c56de))


### Features

* Add Node.getEndLineNumber() ([f00ca4c](https://github.com/dsherret/ts-morph/commit/f00ca4c))
* Add Symbol.getValueDeclaration() ([91da111](https://github.com/dsherret/ts-morph/commit/91da111))
* Improve inserting to ArrayLiteralExpressions. ([b2e991f](https://github.com/dsherret/ts-morph/commit/b2e991f))



# ts-simple-ast [6.8.0](https://github.com/dsherret/ts-morph/compare/tsa-6.7.0...tsa-6.8.0) (2018-02-01)


### Features

* Add Node.getFullStart ([9d44185](https://github.com/dsherret/ts-morph/commit/9d44185))
* Upgrade support to TypeScript 2.7. ([dab428a](https://github.com/dsherret/ts-morph/commit/dab428a))



# ts-simple-ast [6.7.0](https://github.com/dsherret/ts-morph/compare/tsa-6.6.0...tsa-6.7.0) (2018-01-28)


### Bug Fixes

* **type-guards:** A few nodes were not returning true for some type guards. ([f2f64b6](https://github.com/dsherret/ts-morph/commit/f2f64b6))


### Features

* Add CallSignatureDeclaration. ([3067c2b](https://github.com/dsherret/ts-morph/commit/3067c2b))
* Add ClassDeclaration - getExtendsOrThrow() and getBaseClassOrThrow. ([3e24db4](https://github.com/dsherret/ts-morph/commit/3e24db4))
* Add ExternalModuleReference and ImportEqualsDeclaration. ([c140982](https://github.com/dsherret/ts-morph/commit/c140982)), closes [#225](https://github.com/dsherret/ts-morph/issues/225)
* StatementedNode - getStatement(condition) and getStatementByKind(kind). ([db34a13](https://github.com/dsherret/ts-morph/commit/db34a13))



# ts-simple-ast [6.6.0](https://github.com/dsherret/ts-morph/compare/tsa-6.5.0...tsa-6.6.0) (2018-01-27)


### Bug Fixes

* ClassDeclaration.getBaseClass should return the base class when using mixins. ([b455c60](https://github.com/dsherret/ts-morph/commit/b455c60))
* Exceptions occurring when synchronously calling forgetNodesCreatedInBlock weren't being thrown. ([82798c1](https://github.com/dsherret/ts-morph/commit/82798c1))


### Features

* [#138](https://github.com/dsherret/ts-morph/issues/138) - getInitializerIfKind improvement. ([e0b88ba](https://github.com/dsherret/ts-morph/commit/e0b88ba))
* Add SourceFile getRelativePathToSourceFile and getRelativePathToSourceFileAsModuleSpecifier. ([99e8585](https://github.com/dsherret/ts-morph/commit/99e8585))
* Node.getStartLineNumber and SourceFile.getLineNumberFromPos. ([64178fa](https://github.com/dsherret/ts-morph/commit/64178fa))



# ts-simple-ast [6.5.0](https://github.com/dsherret/ts-morph/compare/tsa-6.4.0...tsa-6.5.0) (2018-01-26)


### Bug Fixes

* The wrapped Type should be a TypeParameter when it is a ts.TypeParameter. ([23e7e94](https://github.com/dsherret/ts-morph/commit/23e7e94))


### Features

* Add Node.getType() ([2f15bd9](https://github.com/dsherret/ts-morph/commit/2f15bd9))
* Add Type.isTypeParameter type guard. ([02c591f](https://github.com/dsherret/ts-morph/commit/02c591f))



# ts-simple-ast [6.4.0](https://github.com/dsherret/ts-morph/compare/tsa-6.3.0...tsa-6.4.0) (2018-01-21)


### Features

* [#231](https://github.com/dsherret/ts-morph/issues/231) - Node.formatText() - Format individual nodes. ([34f61ea](https://github.com/dsherret/ts-morph/commit/34f61ea))
* InterfaceDeclaration - getBaseTypes() and getBaseDeclarations() ([9785eeb](https://github.com/dsherret/ts-morph/commit/9785eeb))



# ts-simple-ast [6.3.0](https://github.com/dsherret/ts-morph/compare/tsa-6.2.0...tsa-6.3.0) (2018-01-20)


### Bug Fixes

* ExportableNode.setIsExported should not remove a default export on a different line. ([fe0bcc0](https://github.com/dsherret/ts-morph/commit/fe0bcc0))
* Fixes setting node as a default export in ambientable situation would throw. ([66ac7e6](https://github.com/dsherret/ts-morph/commit/66ac7e6))
* Some interfaces were missing from being exported from the main file. ([5330aba](https://github.com/dsherret/ts-morph/commit/5330aba))


### Features

* ExportSpecifier - getLocalTargetSymbol() and getLocalTargetDeclarations() ([30eff42](https://github.com/dsherret/ts-morph/commit/30eff42))
* ImportDeclaration & ExportDeclaration - getModuleSpecifierSourceFile ([a42d6a1](https://github.com/dsherret/ts-morph/commit/a42d6a1))
* SourceFile - getExportedDeclarations() ([61663aa](https://github.com/dsherret/ts-morph/commit/61663aa))
* TypeGuards.hasName(node) ([efed188](https://github.com/dsherret/ts-morph/commit/efed188))



# ts-simple-ast [6.2.0](https://github.com/dsherret/ts-morph/compare/tsa-6.1.0...tsa-6.2.0) (2018-01-14)


### Bug Fixes

* Removing a member throws when surrounding members have JS docs. ([fdc64c9](https://github.com/dsherret/ts-morph/commit/fdc64c9))


### Features

* Node .getStart & .getStartLinePos - add includeJsDocComment. ([af8bb55](https://github.com/dsherret/ts-morph/commit/af8bb55))



# ts-simple-ast [6.1.0](https://github.com/dsherret/ts-morph/compare/tsa-6.0.1...tsa-6.1.0) (2018-01-14)


### Bug Fixes

* Fix JSDocParameterTag not being wrapped. ([7363481](https://github.com/dsherret/ts-morph/commit/7363481))
* Fix TypeAssertion not being wrapped. ([58fc48c](https://github.com/dsherret/ts-morph/commit/58fc48c))
* Less strict ClassDeclaration getBaseClass ([033deb8](https://github.com/dsherret/ts-morph/commit/033deb8))
* TypeGuards utility was missing some nodes. ([3ddca5d](https://github.com/dsherret/ts-morph/commit/3ddca5d))


### Features

* [#187](https://github.com/dsherret/ts-morph/issues/187) - Added TypeGuards.hasExpression. ([6e37480](https://github.com/dsherret/ts-morph/commit/6e37480))
* Add .getType() to InterfaceDeclaration and ClassDeclaration. ([3c8ca33](https://github.com/dsherret/ts-morph/commit/3c8ca33))
* Add JSDocableNode to ExpressionStatement and LabeledStatement. ([00c2a89](https://github.com/dsherret/ts-morph/commit/00c2a89)), closes [#193](https://github.com/dsherret/ts-morph/issues/193)



# ts-simple-ast [6.0.1](https://github.com/dsherret/ts-morph/compare/tsa-6.0.0...tsa-6.0.1) (2018-01-13)


### Bug Fixes

* Accidentally released with no jsdocs. ([cf58690](https://github.com/dsherret/ts-morph/commit/cf58690))


# ts-simple-ast [6.0.0](https://github.com/dsherret/ts-morph/compare/tsa-5.6.0...tsa-6.0.0) (2018-01-13)


### Bug Fixes

* [#203](https://github.com/dsherret/ts-morph/issues/203) - Source file will now be marked as "saved" when updating from file system. ([65f22ac](https://github.com/dsherret/ts-morph/commit/65f22ac))
* [#218](https://github.com/dsherret/ts-morph/issues/218) - Throw an error when a node is constructed outside the library. ([74fa8c1](https://github.com/dsherret/ts-morph/commit/74fa8c1))
* Virtual file system properly handles multiple globs. ([74aaca7](https://github.com/dsherret/ts-morph/commit/74aaca7))


### Code Refactoring

* project.addExistingSourceFiles now takes either a single glob or multiple globs passed as an array. ([fb5b930](https://github.com/dsherret/ts-morph/commit/fb5b930))


### Features

* [#7](https://github.com/dsherret/ts-morph/issues/7) - Ability to import files from tsconfig. ([b538537](https://github.com/dsherret/ts-morph/commit/b538537))
* [#7](https://github.com/dsherret/ts-morph/issues/7) - Some fixes to importing files from tsconfig. ([2a95bc2](https://github.com/dsherret/ts-morph/commit/2a95bc2))
* [#7](https://github.com/dsherret/ts-morph/issues/7) - Specified compiler options and tsconfig path are both used to determine added files. ([20e7b77](https://github.com/dsherret/ts-morph/commit/20e7b77))
* Support multiple globs when getting source files. ([bb935d9](https://github.com/dsherret/ts-morph/commit/bb935d9))


### BREAKING CHANGES

* Use an array when passing in multiple file globs to project.addExistingSourceFiles. This better expresses the intent of this method call.
* Files are added based on the tsconfig by default. `getCompilerOptionsFromTsConfig` now returns an object that includes the diagnostics.



# ts-simple-ast [5.6.0](https://github.com/dsherret/ts-morph/compare/tsa-5.3.2...tsa-5.6.0) (2018-01-13)


### Features

* [#103](https://github.com/dsherret/ts-morph/issues/103) - ClassDeclaration: Add .getBaseTypes() and .getBaseClass() ([e84252b](https://github.com/dsherret/ts-morph/commit/e84252b))
* [#204](https://github.com/dsherret/ts-morph/issues/204) - Add IfStatement. ([095eb24](https://github.com/dsherret/ts-morph/commit/095eb24))
* [#204](https://github.com/dsherret/ts-morph/issues/204) - Add IterationStatement, Do, ForIn, ForOf, For, While ([ce40dee](https://github.com/dsherret/ts-morph/commit/ce40dee))
* [#204](https://github.com/dsherret/ts-morph/issues/204) - Add WithStatement. ([215383a](https://github.com/dsherret/ts-morph/commit/215383a))
* [#213](https://github.com/dsherret/ts-morph/issues/213) - Add NoSubstitutionTemplateLiteral. ([e0fd583](https://github.com/dsherret/ts-morph/commit/e0fd583))
* Add printNode utility function and Node.print() ([d6c2313](https://github.com/dsherret/ts-morph/commit/d6c2313))



# ts-simple-ast [5.5.0](https://github.com/dsherret/ts-morph/compare/tsa-5.3.2...tsa-5.5.0) (2018-01-11)

Thanks once again to thanks to [@dicarlo2](https://github.com/dicarlo2) for implementing a lot of new expression classes.

### Features

* [#103](https://github.com/dsherret/ts-morph/issues/103) - ClassDeclaration: Add .getBaseTypes() and .getBaseClass() ([e84252b](https://github.com/dsherret/ts-morph/commit/e84252b))
* [#204](https://github.com/dsherret/ts-morph/issues/204) - Add IfStatement. ([095eb24](https://github.com/dsherret/ts-morph/commit/095eb24))
* [#204](https://github.com/dsherret/ts-morph/issues/204) - Add IterationStatement, Do, ForIn, ForOf, For, While ([ce40dee](https://github.com/dsherret/ts-morph/commit/ce40dee))
* [#204](https://github.com/dsherret/ts-morph/issues/204) - Add WithStatement. ([215383a](https://github.com/dsherret/ts-morph/commit/215383a))
* [#213](https://github.com/dsherret/ts-morph/issues/213) - Add NoSubstitutionTemplateLiteral. ([e0fd583](https://github.com/dsherret/ts-morph/commit/e0fd583))



# ts-simple-ast [5.4.0](https://github.com/dsherret/ts-morph/compare/tsa-5.3.2...tsa-5.4.0) (2018-01-10)

All statement nodes are wrapped thanks to [@dicarlo2](https://github.com/dicarlo2)!

### Features

* [#204](https://github.com/dsherret/ts-morph/issues/204) - Add IfStatement. ([095eb24](https://github.com/dsherret/ts-morph/commit/095eb24))
* [#204](https://github.com/dsherret/ts-morph/issues/204) - Add IterationStatement, Do, ForIn, ForOf, For, While ([ce40dee](https://github.com/dsherret/ts-morph/commit/ce40dee))
* [#204](https://github.com/dsherret/ts-morph/issues/204) - Add WithStatement. ([215383a](https://github.com/dsherret/ts-morph/commit/215383a))



## ts-simple-ast [5.3.2](https://github.com/dsherret/ts-morph/compare/tsa-5.3.1...tsa-5.3.2) (2018-01-06)


### Bug Fixes

* [#203](https://github.com/dsherret/ts-morph/issues/203) - Source file will now be marked as "saved" when updating from file system. ([fa0dd2c](https://github.com/dsherret/ts-morph/commit/fa0dd2c))



## ts-simple-ast [5.3.1](https://github.com/dsherret/ts-morph/compare/tsa-5.3.0...tsa-5.3.1) (2018-01-02)


### Bug Fixes

* Directory.getSourceFile should only return source files currently existing within the cache. ([8db2d84](https://github.com/dsherret/ts-morph/commit/8db2d84))



# ts-simple-ast [5.3.0](https://github.com/dsherret/ts-morph/compare/tsa-5.2.0...tsa-5.3.0) (2018-01-02)


### Bug Fixes

* [#137](https://github.com/dsherret/ts-morph/issues/137) - Improve error message when manipulation throws error. ([34620f0](https://github.com/dsherret/ts-morph/commit/34620f0))
* Changing from namespace to module keyword and vice versa will now change the node kind. ([38dc73b](https://github.com/dsherret/ts-morph/commit/38dc73b))


### Features

* [#200](https://github.com/dsherret/ts-morph/issues/200) - Add BooleanLiteral. ([6cc7917](https://github.com/dsherret/ts-morph/commit/6cc7917))
* [#201](https://github.com/dsherret/ts-morph/issues/201) - Add BinaryExpression. ([71a75bf](https://github.com/dsherret/ts-morph/commit/71a75bf))
* Add Directory.getDescendantDirectories. ([d576acb](https://github.com/dsherret/ts-morph/commit/d576acb))



# ts-simple-ast [5.2.0](https://github.com/dsherret/ts-morph/compare/tsa-5.1.0...tsa-5.2.0) (2017-12-26)


### Features

* Ability to get source file from directory based on relative or absolute path. ([fb72396](https://github.com/dsherret/ts-morph/commit/fb72396))



# ts-simple-ast [5.1.0](https://github.com/dsherret/ts-morph/compare/tsa-5.0.0...tsa-5.1.0) (2017-12-26)


### Features

* Add overwrite option to source file and directory copy. ([0741180](https://github.com/dsherret/ts-morph/commit/0741180))



# ts-simple-ast [5.0.0](https://github.com/dsherret/ts-morph/compare/tsa-4.2.1...tsa-5.0.0) (2017-12-26)


### Bug Fixes

* [#195](https://github.com/dsherret/ts-morph/issues/195) - Fixes emitting directory crashes when directory does not exist. ([57c3381](https://github.com/dsherret/ts-morph/commit/57c3381))
* [#196](https://github.com/dsherret/ts-morph/issues/196) - Fixes directory.copy() crashing when directory already exists. ([def2992](https://github.com/dsherret/ts-morph/commit/def2992))


### Code Refactoring

* [#181](https://github.com/dsherret/ts-morph/issues/181) Rename DocumentationableNode to JSDocableNode. ([59a254e](https://github.com/dsherret/ts-morph/commit/59a254e))
* Getting and inserting/adding imports method names now includes "Declaration". ([97812cf](https://github.com/dsherret/ts-morph/commit/97812cf))


### Features

* [#177](https://github.com/dsherret/ts-morph/issues/177) - Ability to use virtual file system. ([ae27f5b](https://github.com/dsherret/ts-morph/commit/ae27f5b))
* [#191](https://github.com/dsherret/ts-morph/issues/191) - Add SourceFile.getEmitOutput(). ([1707a7d](https://github.com/dsherret/ts-morph/commit/1707a7d))
* [#194](https://github.com/dsherret/ts-morph/issues/194) - Add async version of forget block. ([c73dd05](https://github.com/dsherret/ts-morph/commit/c73dd05))
* Ability to get a directory from directory based on a relative path. ([b7714c5](https://github.com/dsherret/ts-morph/commit/b7714c5))
* Add addDirectoryIfExists and addSourceFileIfExists ([0ff4ff2](https://github.com/dsherret/ts-morph/commit/0ff4ff2))
* Add project.getFileSystem() ([3364349](https://github.com/dsherret/ts-morph/commit/3364349))
* Add ExportAssignment. ([f2b346b](https://github.com/dsherret/ts-morph/commit/f2b346b))


### BREAKING CHANGES

* All import methods on SourceFile have been renamed to include "declaration" (ex. getImports() -> getImportDeclarations()). This was done for consistency with getExports() -> getExportDeclarations().
* getDocs(), insertDoc(), etc. have been renamed to getJsDocs(), insertJsDoc(), etc...
* All export methods on SourceFile have been renamed to include "declaration" (ex. getExports() -> getExportDeclarations())



## ts-simple-ast [4.2.1](https://github.com/dsherret/ts-morph/compare/tsa-4.2.0...tsa-4.2.1) (2017-12-23)


### Bug Fixes

* For consistency, directory path should be relative to its path and not the parent. ([f832035](https://github.com/dsherret/ts-morph/commit/f832035))



# ts-simple-ast [4.2.0](https://github.com/dsherret/ts-morph/compare/tsa-4.1.0...tsa-4.2.0) (2017-12-23)


### Bug Fixes

* [#192](https://github.com/dsherret/ts-morph/issues/192) - Fix forget block crashes when removing node. ([3f195ea](https://github.com/dsherret/ts-morph/commit/3f195ea))
* getDiagnostics() should return the syntactic, semantic, and declaration diagnostics. ([5ea5cfc](https://github.com/dsherret/ts-morph/commit/5ea5cfc))
* Lazily create program and type checker when necessary. ([77b3889](https://github.com/dsherret/ts-morph/commit/77b3889))


### Features

* [#184](https://github.com/dsherret/ts-morph/issues/184) - Ability to copy directories. ([18f1e7b](https://github.com/dsherret/ts-morph/commit/18f1e7b))
* [#185](https://github.com/dsherret/ts-morph/issues/185) - Ability to save all descendant files in a directory. ([334f20b](https://github.com/dsherret/ts-morph/commit/334f20b))
* Add project.getPreEmitDiagnostics() ([a561994](https://github.com/dsherret/ts-morph/commit/a561994))
* Add SourceFile.getPreEmitDiagnostics ([d1ea9eb](https://github.com/dsherret/ts-morph/commit/d1ea9eb))
* Emit a directory. ([3cb455c](https://github.com/dsherret/ts-morph/commit/3cb455c))
* Program - getSyntacticDiagnostics, getSemanticDiagnostics, getDeclarationDiagnostics, getPreEmitDiagnostics ([56b5f58](https://github.com/dsherret/ts-morph/commit/56b5f58))
* Support TS 2.4, 2.5, and 2.6 ([57c87f8](https://github.com/dsherret/ts-morph/commit/57c87f8))
* Wrap LanguageService.getEmitOutput(...). ([40ecc32](https://github.com/dsherret/ts-morph/commit/40ecc32))



# ts-simple-ast [4.1.0](https://github.com/dsherret/ts-morph/compare/tsa-4.0.1...tsa-4.1.0) (2017-12-19)


### Bug Fixes

* replaceWithText should include the js docs if they exist. ([304a86a](https://github.com/dsherret/ts-morph/commit/304a86a))


### Features

* [#180](https://github.com/dsherret/ts-morph/issues/180) - Directory - isAncestorOf and isDescendantOf ([7b259d9](https://github.com/dsherret/ts-morph/commit/7b259d9))



## ts-simple-ast [4.0.1](https://github.com/dsherret/ts-morph/compare/tsa-4.0.0...tsa-4.0.1) (2017-12-17)


### Bug Fixes

* createDirectory should throw if the directory exists. ([93a9da2](https://github.com/dsherret/ts-morph/commit/93a9da2))



# ts-simple-ast [4.0.0](https://github.com/dsherret/ts-morph/compare/tsa-3.2.0...tsa-4.0.0) (2017-12-17)


### Code Refactoring

* [#170](https://github.com/dsherret/ts-morph/issues/170) - Rename methods on main api. ([07f27c4](https://github.com/dsherret/ts-morph/commit/07f27c4))


### Features

* [#169](https://github.com/dsherret/ts-morph/issues/169) - Directories. ([332c44d](https://github.com/dsherret/ts-morph/commit/332c44d))
* [#173](https://github.com/dsherret/ts-morph/issues/173) - SemicolonToken type guard. ([77d600a](https://github.com/dsherret/ts-morph/commit/77d600a))
* [#174](https://github.com/dsherret/ts-morph/issues/174) - Getting a source file by name or condition walks directories. ([e4f4b45](https://github.com/dsherret/ts-morph/commit/e4f4b45))


### BREAKING CHANGES

* Renamed methods for creating & adding source files. See #170 for details.



# ts-simple-ast [3.2.0](https://github.com/dsherret/ts-morph/compare/tsa-3.1.0...tsa-3.2.0) (2017-12-12)


### Features

* [#166](https://github.com/dsherret/ts-morph/issues/166) - Add ReturnStatement. ([23eccf1](https://github.com/dsherret/ts-morph/commit/23eccf1))
* [#168](https://github.com/dsherret/ts-morph/issues/168) - Add SourceFile.refreshFromFileSystem() ([9ddcdd4](https://github.com/dsherret/ts-morph/commit/9ddcdd4))
* Add Node.getSymbolOrThrow() ([6abbe7f](https://github.com/dsherret/ts-morph/commit/6abbe7f))
* Add SourceFile.getDirectoryPath(). ([708f3bb](https://github.com/dsherret/ts-morph/commit/708f3bb))
* Get exports from symbol. ([c815955](https://github.com/dsherret/ts-morph/commit/c815955))



# ts-simple-ast [3.1.0](https://github.com/dsherret/ts-morph/compare/tsa-3.0.2...tsa-3.1.0) (2017-12-10)


### Features

* [#164](https://github.com/dsherret/ts-morph/issues/164) - Support ExpressionStatements. ([d7d48a1](https://github.com/dsherret/ts-morph/commit/d7d48a1))
* Support deleting a file from the file system. ([326b6e0](https://github.com/dsherret/ts-morph/commit/326b6e0))



## ts-simple-ast [3.0.2](https://github.com/dsherret/ts-morph/compare/tsa-3.0.1...tsa-3.0.2) (2017-12-10)


### Bug Fixes

* **manipulation:** Brace possibly placed at wrong indentation when manipulating comma & newline separated node. ([5318c0f](https://github.com/dsherret/ts-morph/commit/5318c0f))



## ts-simple-ast [3.0.1](https://github.com/dsherret/ts-morph/compare/tsa-3.0.0...tsa-3.0.1) (2017-12-09)



# ts-simple-ast [3.0.0](https://github.com/dsherret/ts-morph/compare/tsa-2.0.0...tsa-3.0.0) (2017-12-09)


### Bug Fixes

* ShorthandPropertyAssignment.removeObjectAssignmentInitializer was incorrectly returning undefined. ([62e2971](https://github.com/dsherret/ts-morph/commit/62e2971))


### Code Refactoring

* [#160](https://github.com/dsherret/ts-morph/issues/160) - Remove DocumentationableNode.getDocumentationComment ([54c94b1](https://github.com/dsherret/ts-morph/commit/54c94b1))


### Features

* [#131](https://github.com/dsherret/ts-morph/issues/131) - Ability to add statements within blocks. ([f2bb4de](https://github.com/dsherret/ts-morph/commit/f2bb4de))
* [#145](https://github.com/dsherret/ts-morph/issues/145) - Add JSDoc.getInnerText - Returns text without surrounding comment. ([a62cec4](https://github.com/dsherret/ts-morph/commit/a62cec4))
* [#161](https://github.com/dsherret/ts-morph/issues/161) - Rename getDocumentationCommentNodes to getDocNodes ([d29820f](https://github.com/dsherret/ts-morph/commit/d29820f))
* [#42](https://github.com/dsherret/ts-morph/issues/42) - Ability to pass in type checker to wrapped node. ([62b377f](https://github.com/dsherret/ts-morph/commit/62b377f))
* [#59](https://github.com/dsherret/ts-morph/issues/59) - Get parameter, type parameter, or decorator by name. ([f889515](https://github.com/dsherret/ts-morph/commit/f889515))


### BREAKING CHANGES

* Removed DocumentationableNode.getDocumentationComment.
* getDocumentationCommentNodes is now getDocNodes.
* createWrappedNode's signature changed.



# ts-simple-ast [2.0.0](https://github.com/dsherret/ts-morph/compare/tsa-1.3.0...tsa-2.0.0) (2017-12-08)


### Features

* [#37](https://github.com/dsherret/ts-morph/issues/37) - Add StringLiteral.getQuoteType ([adad446](https://github.com/dsherret/ts-morph/commit/adad446))
* SourceFile.formatText uses the formatting API. ([02e3feb](https://github.com/dsherret/ts-morph/commit/02e3feb)), closes [#157](https://github.com/dsherret/ts-morph/issues/157) [#158](https://github.com/dsherret/ts-morph/issues/158)


### BREAKING CHANGES

* StringChar renamed to QuoteType. Manipulation setting's getStringChar() renamed to getQuoteType().

This was done for consistency.
* SourceFile.formatText now takes a FormatCodeSettings argument.



# ts-simple-ast [1.3.0](https://github.com/dsherret/ts-morph/compare/tsa-1.2.0...tsa-1.3.0) (2017-12-05)


### Bug Fixes

* [#150](https://github.com/dsherret/ts-morph/issues/150) - Fix SourceFile.addImport not using the specified string char. ([e704330](https://github.com/dsherret/ts-morph/commit/e704330))


### Features

* Upgrade to code-block-writer 6.2.0 ([155f935](https://github.com/dsherret/ts-morph/commit/155f935))



# ts-simple-ast [1.2.0](https://github.com/dsherret/ts-morph/compare/tsa-1.1.0...tsa-1.2.0) (2017-12-04)


### Bug Fixes

* [#149](https://github.com/dsherret/ts-morph/issues/149) - "SourceFile.formatText() should respect indentation settings" ([b0b9e53](https://github.com/dsherret/ts-morph/commit/b0b9e53))


### Features

* Add isInStringAtPos to Node. ([cfcf256](https://github.com/dsherret/ts-morph/commit/cfcf256))



# ts-simple-ast [1.1.0](https://github.com/dsherret/ts-morph/compare/tsa-1.0.0...tsa-1.1.0) (2017-12-03)


### Features

* [#65](https://github.com/dsherret/ts-morph/issues/65) - Navigation and manipulation of object literal expressions. ([d9d1621](https://github.com/dsherret/ts-morph/commit/d9d1621))



# ts-simple-ast [1.0.0](https://github.com/dsherret/ts-morph/compare/tsa-0.99.0...tsa-1.0.0) (2017-11-28)


### Bug Fixes

* Renamed setIsOptional to setHasQuestionToken for consistency. ([ac45bba](https://github.com/dsherret/ts-morph/commit/ac45bba))


### BREAKING CHANGES

* QuestionTokenableNode.setIsOptional is now setHasQuestionToken.



# ts-simple-ast [0.99.0](https://github.com/dsherret/ts-morph/compare/tsa-0.98.0...tsa-0.99.0) (2017-11-28)


### Features

* **Manipulation:** [#65](https://github.com/dsherret/ts-morph/issues/65) - Setting and removing initializers from (Shorthand)PropertyAssignments ([dc3a61c](https://github.com/dsherret/ts-morph/commit/dc3a61c))
* **Node:** Getting child of node at index. ([cb0a800](https://github.com/dsherret/ts-morph/commit/cb0a800))



# ts-simple-ast [0.98.0](https://github.com/dsherret/ts-morph/compare/tsa-0.97.0...tsa-0.98.0) (2017-11-27)


### Features

* **navigation:** [#140](https://github.com/dsherret/ts-morph/issues/140) - Forget blocks. ([f5a8b39](https://github.com/dsherret/ts-morph/commit/f5a8b39))


### Performance Improvements

* Don't internally add nodes to the cache so often for common navigation methods. ([7efc147](https://github.com/dsherret/ts-morph/commit/7efc147))

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Playnite is an open source video game library manager/launcher (C#, WPF, .NET Framework 4.6.2, **Windows-only**, x86 platform). This is the Playnite 10 codebase; Playnite 11 is being rewritten in a private repo, so PRs are paused except small "safe" changes that come with test coverage. PRs target `devel` (`master` = released build).

The build and tests need Windows + Visual Studio (MSBuild); they won't run on macOS. On this machine, expect to only read and edit code.

## Build and test

- Solution: `source/Playnite.slnx` (restore with `dotnet restore source/Playnite.slnx`, build with MSBuild, platform `x86`).
- Full release build/package: `pwsh build/build.ps1 [-Configuration Debug|Release] [-Package] [-SdkNuget]`. Requires PowerShell 7 and the `powershell-yaml` module. The MSBuild path is hardcoded by default to VS 2026 (`-MSBuildPath` overrides it). It first validates the localization `.xaml` files and the `Emulation/*.yaml` definitions.
- Release config has `TreatWarningsAsErrors=True`. Debug does not. Warnings that pass in Debug can break a Release build.
- Unit tests: NUnit projects in `source/Tests/` (`Playnite.Tests`, `Playnite.DesktopApp.Tests`, `Playnite.FullscreenApp.Tests`, `Playnite.Toolbox.Tests`). Run with `dotnet test` or Visual Studio, e.g. `dotnet test source/Tests/Playnite.Tests --filter "FullyQualifiedName~SomeTest"`. `Playnite.Tests` depends on `TestApp`, `TestGameLibrary` and `TestPlugin`, which are copied into its output dir by post-build xcopy steps.
- UI/integration tests: Pester scripts in `tests/` (`tests/RunTests.ps1 [-TestName "<name>"]`). They need `Pester`, `PSNativeAutomation` and `powershell-yaml`, plus a `TestConfig.yaml` based on `TestConfig.Template.yaml`.
- Other build scripts: `build/updateLocalizations.ps1`, `build/buildLocConstants.ps1` (regenerates localization constants), `build/VerifyLanguageFiles.ps1`.

## Architecture

Projects in `source/`:

- **`Playnite`**: the core library shared by both UIs. It holds the game database (`Database/GameDatabase.cs` plus migrations), settings (`Settings/PlayniteSettings.cs`), `GamesEditor` (launch, install and edit game logic), the extension loader (`Plugins/ExtensionFactory.cs`, `ExtensionInstaller.cs`), emulation support (`Emulation/`, driven by `Platforms.yaml`, `Regions.yaml` and emulator definitions), metadata downloading, scripting (PowerShell) and localization.
- **`Playnite.DesktopApp`** and **`Playnite.FullscreenApp`**: two separate WPF front ends (mouse/desktop vs. controller/fullscreen) on top of `Playnite`. Each has its own `Application` class, `ViewModels`, `Windows`, `Controls`, `Themes` and `Api` implementation of the SDK. The UI follows MVVM, so a feature that touches both modes usually needs changes in both apps. Shared view-model logic lives in `Playnite/ViewModels`.
- **`PlayniteSDK`** (`Playnite.SDK`): the public API for plugins and themes, published as a NuGet package. Changes here are public API changes. Keep them backward compatible and respect `SdkVersions.cs`. Interfaces such as `IPlayniteAPI` are implemented in the app projects.
- **`Playnite.BrowserProcess`**: separate CEF browser subprocess used by the web views.
- **`Playnite.Deps`**: bundles dependencies.
- **`Tools/`**: `Playnite.Toolbox` (CLI for creating extension and theme templates, from `Templates/`), `Playnite.Utilities`, `PlayniteInstaller`.
- **`Tests/`**: besides the unit test projects, `TestApp`, `TestGameLibrary`, `TestMetadataPlugin` and `TestPlugin` are helper projects used by the tests.

Extensibility model: plugins (.NET), PowerShell scripts and XAML themes are all loaded at runtime through `ExtensionFactory`. The SDK is their only supported contract.

Localization: English source strings are in `source/Playnite/Localization/LocSource.xaml`. Other `*.xaml` locale files are managed through Crowdin (`crowdin.yml`), so edit only `LocSource.xaml` by hand.

## Code style (from README)

- private fields and properties: camelCase, no underscore prefix. All methods: PascalCase.
- 4 spaces, no tabs.
- Empty line between a closing `}` and a following statement.
- Always use curly braces after `if`/`for`/`foreach`/`while`, even for single statements.

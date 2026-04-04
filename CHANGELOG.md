# Changelog

## 2.0.2 — 2026-04-04

+ Scripts can now emit their own JSON decisions, bypassing hooksmith's wrapper
* Eval outputs the correct JSON schema per event type (Stop, UserPromptSubmit, PostToolUse each get their own format)
* Rule lookup switched to event-keyed map — roughly 4-7x faster on a typical ruleset
! Stop and SubagentStop hooks were emitting PreToolUse-shaped JSON, which Claude Code rejected
! UserPromptSubmit context output was missing the hookEventName field

## 2.0.1 — 2026-04-03

! Fixed hooks.json being rewritten at runtime into the plugin cache, which Claude Code's sandbox blocks — all events are now pre-registered statically
! Fixed MAP_FILE using a relative CWD path instead of ~/.config/hooksmith/.map.json
! Fixed `hooksmith list` showing "—" for prompt rules instead of "prompt"
+ Added `hooksmith doctor` — checks for v1-format rules, missing scripts, and empty rule directories
* SessionStart now rebuilds the map directly instead of shelling out to init.sh

## 2.0.0 — 2026-04-03

+ Rule map with O(1) lookups replaces the old build system
+ Rules can live across multiple files, split between project and user scopes
+ Live evaluation, no compilation step
+ Inline check mechanism for writing hook logic directly in rules
+ Compact rule format
+ Four new example rules: code-style-advisor, port-scan-guard, security-review, sudo-guard
* Core runtime uses map-based indexing
* CLI routes through the map instead of parsed output
* check and script merged into one "run" mechanism
* Library reorganized; examples and tests updated
! Hook output now matches the official Claude Code hooks spec
- Build system removed
- parse.sh removed

## 1.0.1 — 2026-03-24

+ Add Stop event hooks for workflow enforcement (AskUserQuestion gate, spec-first reinforcement)
* Remove auto-build mechanism from SessionStart — hook rebuilds now require explicit 'hooksmith build' command
- Remove auto-build.sh dead code from lib directory

## 1.0.0 — 2026-03-24

+ Added lean-hook-engine plugin with comprehensive hook system
+ Added hooksmith CLI with ID-based registry and runner system
+ Added hooksmith skill for guided hook creation and management
+ Added hooksmith `start` subcommand for SessionStart hook support
+ Added `convert` and `build` subcommands to hooksmith CLI
+ Added end-to-end hook creation workflow
+ Added notification and post-compact hooks
+ Added comprehensive hook engine test suite
+ Added comprehensive engine test suite for regex field routing and action types
+ Added supported fields documentation table for hooksmith rule format
+ Added hook examples and documentation

* Changed hook rule paths to hooksmith convention
* Refactored away rule-author skill (replaced by hooksmith)

! Fixed hardcoded username paths by replacing with HOME variable
! Fixed test fixture field naming (prompt → user_prompt) for UserPromptSubmit compatibility

- Removed rule-author skill (replaced by hooksmith)

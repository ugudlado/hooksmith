# Changelog

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

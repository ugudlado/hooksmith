---
name: release-prep
description: "Prepare a release — changelog, version bumps, and git tag"
argument-hint: "<version>"
allowed-tools: ["Bash", "Read", "Edit", "Glob"]
model: haiku
---

# Release Prep

Prepare a release for hooksmith: generate changelog from commits since last tag, update versions, tag, push, and create GitHub release.

## Arguments

$ARGUMENTS — The version tag to create, e.g. v1.2.0 or 1.2.0. Normalize to x.y.z for changelog headings and vx.y.z for git tags.

## Process

### 1. Determine Range

Find the latest existing git tag and list commits between it and HEAD:

```bash
git describe --tags --abbrev=0 2>/dev/null
git log <LAST_TAG>..HEAD --oneline
```

If no previous tag exists, use all commits.

### 2. Analyze Commits

Read each commit message and classify into:

- Added, marked with + prefix: New features, new rules, new mechanisms.
- Changed, marked with * prefix: Refactors, improvements, behavior changes.
- Fixed, marked with ! prefix: Bug fixes.
- Removed, marked with - prefix: Deleted features, removed code paths.

Rules:

- Keep descriptions concise, one line per change
- Within each group, order: + first, then *, then !, then -

### 3. Draft Changelog Entry

Present the draft to the user in this format:

```
## x.y.z — YYYY-MM-DD

+ Added feature description
* Changed something
! Fixed a bug
- Removed something
```

WAIT for user approval before writing.

### 4. Update Files

After approval, update all version files:

**a) CHANGELOG.md** — Insert the approved entry below the `# Changelog` heading, above the previous release. Create CHANGELOG.md if it does not exist.

**b) `.claude-plugin/plugin.json`** — Bump the `"version"` field to x.y.z.

**c) `$HOME/code/claude-marketplace/.claude-plugin/marketplace.json`** — Bump the `"version"` for the `hooksmith` plugin entry to x.y.z.

Read each file before editing. Use Edit to update version fields in-place.

### 5. Commit and Tag

Stage all changed files:

```bash
git add CHANGELOG.md .claude-plugin/plugin.json
git commit -m "chore: release vx.y.z"
git tag vx.y.z
```

Then in the marketplace repo, commit the version bump:

```bash
cd $HOME/code/claude-marketplace
git add .claude-plugin/marketplace.json
git commit -m "chore: bump hooksmith to vx.y.z"
```

### 6. Push and Create GitHub Release

Push commits and tags:

```bash
cd $HOME/code/hooksmith
git push origin main --tags
```

```bash
cd $HOME/code/claude-marketplace
git push
```

Extract the changelog entry for this version into a temp file, then create the GitHub release:

```bash
cd $HOME/code/hooksmith
gh release create vx.y.z \
  --title "vx.y.z" \
  --notes-file <temp-changelog-file>
```

### 7. Report

Output:

- Release version
- Number of changelog entries
- Files updated
- Tag name created
- GitHub release URL

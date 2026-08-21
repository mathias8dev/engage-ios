# Agent Instructions

## Releases and Git tags

- Treat every Git tag as a release operation. Creating or pushing a tag may immediately publish artifacts through the repository's release pipeline.
- Never create, move, delete, recreate, or push a tag unless the user explicitly requests the corresponding release and version.
- A dependency update, version change, successful build, merged release branch, or failed publication does not by itself authorize creating another tag or release.
- Before tagging, work from a clean release commit, verify the package version and native dependency pins, and require the repository's release checks to pass. Keep unrelated or uncommitted work out of the release, using an isolated clean worktree when necessary.
- If publication fails, identify and fix the root cause. Do not invent a new patch version merely to retry. When no immutable artifact was successfully published for the requested version, recreate the same tag on the corrected commit only after verifying that this is safe and remains within the user's explicit release request.
- Once a tag has successfully published an artifact, treat it as immutable. Never move or recreate a successfully released tag.

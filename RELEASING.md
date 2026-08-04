# Releasing

Set `EngageSDKInfo.version` to the exact semantic version to publish, then run `mise run check`.
Swift Package Manager local checkouts are revision-based and therefore do not receive an artificial
package version; only tagged package releases have a semantic version.

Once the commit reaches `main` and CI is green, CI creates the tag and GitHub Release if absent.
`mise run release` is the equivalent manual fallback from a clean local `main`; it reads
`EngageSDKInfo.version` and takes no version argument.

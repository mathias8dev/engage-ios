#!/usr/bin/env bash
set -euo pipefail

version="$(sed -nE 's/^[[:space:]]*public static let version = "([^"]+)".*$/\1/p' Sources/EngageCore/EngageSDKInfo.swift | head -n 1)"
expected_repository="mathias8dev/engage-ios"
./scripts/validate-version.sh "$version"

branch="$(git branch --show-current)"
[[ "$branch" == "main" ]] || { echo "Release must run from main (current: ${branch:-detached})." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash every change before releasing." >&2; exit 1; }

origin="$(git remote get-url origin 2>/dev/null || true)"
[[ "$origin" =~ github\.com[:/]${expected_repository}(\.git)?$ ]] || {
    echo "origin must point to https://github.com/${expected_repository}.git" >&2
    exit 1
}

git fetch origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || {
    echo "Local main must exactly match origin/main before releasing." >&2
    exit 1
}
! git rev-parse -q --verify "refs/tags/$version" >/dev/null || { echo "Tag $version already exists." >&2; exit 1; }

./scripts/check.sh
git tag -a "$version" -m "Release $version"
git push origin "refs/tags/$version"

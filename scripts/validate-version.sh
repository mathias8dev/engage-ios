#!/usr/bin/env bash
set -euo pipefail

declared_version="$(sed -nE 's/^[[:space:]]*public static let version = "([^"]+)".*$/\1/p' Sources/EngageCore/EngageSDKInfo.swift | head -n 1)"
version="${1:-$declared_version}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "Expected a semantic version such as 1.2.3 or 1.2.3-beta.1." >&2
    exit 1
fi

grep -Fq "public static let version = \"$version\"" Sources/EngageCore/EngageSDKInfo.swift || {
    echo "EngageSDKInfo.version must be $version before releasing." >&2
    exit 1
}

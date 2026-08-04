#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "The iOS SDK checks require macOS and Xcode." >&2
    exit 1
fi

destination="${ENGAGE_XCODE_DESTINATION:-}"
if [[ -z "$destination" ]]; then
    device_id="$(xcrun simctl list devices available | sed -nE 's/^.*iPhone.*\(([0-9A-F-]{36})\)[[:space:]]+\((Booted|Shutdown)\).*$/\1/p' | head -n 1)"
    [[ -n "$device_id" ]] || { echo "No available iPhone simulator was found." >&2; exit 1; }
    destination="platform=iOS Simulator,id=$device_id"
fi

xcodebuild test \
    -scheme EngageSDK-Package \
    -destination "$destination" \
    -skipPackagePluginValidation

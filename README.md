# Engage SDK for iOS

Add `https://github.com/mathias8dev/engage-ios.git` as a Swift Package Manager dependency and
select the products needed by the application. `EngageSDK` provides the complete SDK facade;
feature products remain available for modular integrations.

The first public release is `2.1.0`. Releases use full semantic-version tags without a `v` prefix.

Start with verbose diagnostics during local integration:

```swift
import EngageSDK

Engage.start(config: EngageConfig(
    appKey: BuildConfiguration.engageAppKey,
    logLevel: .verbose
))
```

`INFO` is the default. Logs use subsystem `io.engage.sdk` and category `Engage` in Console. They
include lifecycle transitions and the technical `installationId`, but never credentials, tokens,
binding codes, user attribute values or payload values.

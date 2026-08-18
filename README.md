# Engage SDK for iOS

The Engage iOS SDK provides installation and profile management, analytics, feature flags, push,
in-app experiences, and a DivKit-powered Message Center. It is distributed as one Swift package
with a complete facade and independently consumable feature products.

The current release is `2.2.0`. Release tags use semantic versions without a `v` prefix.

## Requirements

- iOS 15 or later
- Swift 5.9 or later
- An Engage application key beginning with `eng_app_`
- APNs capabilities and credentials for push-enabled applications

## Installation

In Xcode, choose **File → Add Package Dependencies** and enter:

```text
https://github.com/mathias8dev/engage-ios.git
```

Select an exact release version and add `EngageSDK` to the application target. That product exposes
the complete facade and activates every feature module. Applications that need a smaller dependency
surface can instead select individual products:

| Product | Responsibility |
| --- | --- |
| `EngageCore` | Installation, profile, privacy, events, actions, flags, preferences, and sync |
| `EngagePush` | APNs token lifecycle, notification events, actions, and receipts |
| `EngagePushServiceExtension` | Extension-safe rich-media attachment handling |
| `EngageInApp` | Remote experience scheduling, evaluation, overlays, and placements |
| `EngageMessageCenter` | Inbox state, pagination, mutations, and rendering documents |
| `EngageMessageCenterDivKit` | SwiftUI inbox and DivKit message rendering |
| `EngageSDK` | Complete facade over all application modules |

DivKit is an internal implementation dependency of the in-app and Message Center rendering
products. Host applications consume server-authored documents; they do not compile generated UI.

## Start the SDK

Start Engage once, during application launch, before accessing another facade property:

```swift
import EngageSDK

Engage.start(config: EngageConfig(
    appKey: BuildConfiguration.engageAppKey,
    logLevel: .verbose
))
```

`Engage.start` synchronously installs a buffering notification delegate before it starts module
work. A notification response delivered during a cold launch is retained until the push module is
ready. The delegate already installed by the host application is preserved and still receives the
same callbacks; Engage unions both foreground presentation decisions.

Use `.verbose` while integrating. `.info` is the default. Logs use subsystem `io.engage.sdk` and
category `Engage` in Console. They include lifecycle transitions and the technical
`installationId`, but never credentials, push tokens, binding codes, user attribute values, or
payload values.

When the same release both upgrades from endpoint-scoped SDK storage and changes the API endpoint,
declare the previous endpoint so Engage can move the correct App Key's durable state:

```swift
EngageConfig(
    appKey: BuildConfiguration.engageAppKey,
    endpoint: BuildConfiguration.engageEndpoint,
    legacyEndpoints: [BuildConfiguration.previousEngageEndpoint]
)
```

This one-time migration option is unnecessary when the endpoint is unchanged. It is explicit so a
process configured with several Engage App Keys never guesses which legacy storage it owns.

## Configure push notifications

Engage sends iOS push notifications directly through APNs. Firebase Cloud Messaging is not part of
this delivery path. Configure the APNs authentication key, Team ID, Key ID, and bundle topic in the
Engage project, then enable **Push Notifications** and the appropriate **Background Modes** in the
application target.

The host application owns the notification permission prompt. Request it at a moment that makes
sense for the product experience:

```swift
import UserNotifications

let center = UNUserNotificationCenter.current()
let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
```

Engage requests APNs registration, but deliberately does not swizzle `UIApplicationDelegate`.
Forward the two APNs registration callbacks:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    Engage.push.didRegisterForRemoteNotifications(deviceToken: deviceToken)
}

func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
) {
    Engage.push.didFailToRegisterForRemoteNotifications(error: error)
}
```

The APNs token is persisted locally and synchronized through the durable SDK operation queue. Token
updates, permission state, opt-in state, notification receipts, and actions are retried when network
access returns. APNs and iOS display eligible background or terminated-state notifications; no SDK
process remains continuously active while the application is terminated. On launch or interaction,
the buffering delegate resumes Engage processing.

Foreground presentation defaults to banner, Notification Center list, sound, and badge. Disable
automatic foreground UI while keeping processing enabled with:

```swift
Engage.start(config: EngageConfig(
    appKey: BuildConfiguration.engageAppKey,
    push: PushConfig(foregroundPresentation: .silent)
))
```

Subscription state is independent from the system permission:

```swift
try await Engage.push.optIn()
try await Engage.push.optOut()

for await event in Engage.push.events {
    // Handle received, opened, dismissed, action-selected, and registration-failure events.
}
```

### Rich media

Add a Notification Service Extension target, link only `EngagePushServiceExtension`, and subclass
the extension-safe base class:

```swift
import EngagePushServiceExtension

final class NotificationService: EngageNotificationServiceExtension {}
```

The extension downloads a valid HTTPS `engage.image_url`, attaches it to the best-attempt content,
and always completes with the original notification when the attachment is absent or unavailable.

## Identify and describe the audience

An Engage installation is created independently from a signed-in profile. Installation-scoped data
survives anonymous use; profile-scoped attributes and tags become available after the backend binds
the installation through the supported identity flow.

```swift
try await Engage.installation.editAttributes {
    $0.set("app_theme", "dark")
    $0.set("onboarding_complete", true)
}

try await Engage.profile.editAttributes {
    $0.set("plan", "pro")
}

try await Engage.profile.editTags {
    $0.add("beta_tester")
}
```

Use `Engage.installation.issueBindingCode()` when the application needs to associate this
installation through the backend identity flow. Treat the returned code as short-lived sensitive
data and send it only to the authenticated backend endpoint responsible for binding.

## Track events and screens

Events feed analytics and local in-app trigger evaluation. Screen state is explicit so visibility
duration and screen-based experiences remain coherent across foreground/background transitions.

```swift
try await Engage.events.track("purchase_completed") {
    $0.set("sku", "annual_pro")
    $0.setValue(99.99)
    $0.setTransactionId("order_123")
}

try await Engage.events.trackScreen("checkout")
try await Engage.events.clearScreen()
```

Pending operations are durable and normally flush automatically. Use
`try await Engage.events.flush()` only when the application needs an explicit synchronization
boundary.

## Render in-app experiences

Overlay experiences are evaluated and presented by `Engage.inApp`. The host may pause presentation
or make a per-experience decision:

```swift
Engage.inApp.overlays.displayDelegate = { content in
    content.experienceId == "blocked_during_payment" ? .deferDisplay : .allow
}

Engage.inApp.overlays.pause()
Engage.inApp.overlays.resume()
```

Embed a server-controlled placement in SwiftUI with:

```swift
import EngageInApp

EngageInAppPlacement("home.hero")
```

The SDK downloads versioned remote documents over HTTPS, stores them locally, evaluates triggers on
device, and renders eligible DivKit documents. It does not require SSE or a WebSocket connection.

## Present the Message Center

The complete product exports a ready-to-use SwiftUI inbox:

```swift
import EngageSDK

EngageMessageCenterView(messageCenter: Engage.messageCenter)
Engage.messageCenter.display()
Engage.messageCenter.display(entryId: entry.id)
```

The ready-made view renders each template's compact `SUMMARY` surface in the list. Selecting the row
pushes a native SwiftUI detail screen and renders the `DETAIL` surface. The entry becomes read only
after that detail is visible. Both
surfaces are immutable snapshots produced from the same headless payload and published template
revision; navigation chrome remains native.

Applications that own their navigation can embed the reusable views directly:

```swift
EngageMessageCenterListView(
    sortOrder: .newestFirst,
    onEntryTap: { entry in router.openMessage(entry.id) }
)

EngageMessageCenterDetailView(
    entryId: entry.id,
    onUnavailable: { router.closeMissingMessage() }
)
```

These views contain no navigation controller or toolbar and share the same Inbox store, rendering
cache, DivKit runtime, and action registry as the ready-made presentation.
The list header presents the synchronized message and unread counts above a compact All/Unread
segmented filter; bulk read mutations remain available through the headless Inbox API.
The list provides the standard trailing swipe actions itself: delete, mark read, and mark unread.
A full swipe never executes the destructive action directly. Selecting delete opens the native SwiftUI
confirmation alert with cancel and destructive actions; only confirmation enqueues the Inbox mutation.

For a custom UI, consume `Engage.messageCenter.inbox.unreadCount`, create a pager with
`Engage.messageCenter.inbox.pager(pageSize: 20, sortOrder: .newestFirst)`, and call the inbox
mutation methods directly. Sorting is server-side on `sentAt`; each order owns a separate cursor
window. Rendering documents remain separate from inbox metadata so a custom list does not need to
understand the DivKit payload until a message is opened.

## Modular integration

When using feature products instead of `EngageSDK`, start `EngageCore` first and explicitly activate
the retained modules. For push, install the launch delegate before asynchronous setup begins:

```swift
import EngageCore
import EngagePush

PushModule.prepareForLaunch()
EngageCore.start(config: config)
let push = PushModule.activate()
```

## Privacy and operational behavior

- Privacy opt-out prevents new audience and analytics operations and clears privacy-sensitive local
  state according to the SDK runtime policy.
- Network mutations are queued durably and retried; UI code does not need to own retry loops.
- Remote configuration and content are cached so eligible experiences and inbox state can be read
  after intermittent connectivity.
- Push transport is APNs on iOS. Firebase configuration is only required when another part of the
  application independently uses Firebase products or FCM.
- Do not put service credentials, APNs keys, or backend secrets in the application bundle.

## Validate from source

The repository uses `mise` to pin its toolchain. On macOS with Xcode installed:

```bash
mise install
mise run check
```

The check resolves dependencies and runs the package test suite against an available iPhone
simulator. CI performs the same validation before creating a version tag and GitHub release.

# Screen Instrumentation

Tracks the screen the user is looking at, attaches its name to every span and log record, and
measures how long each screen took to first appear.

Three pieces:

- **`ScreenTracker`** holds the current screen name and reports each change as one
  `app.navigation.complete` event.
- **`ScreenSpanProcessor`** and **`ScreenLogRecordProcessor`** stamp `app.screen.name` on spans
  and log records, so a network error or a crash says which screen produced it.
- **UIKit swizzling** and the **SwiftUI `otelScreen` modifier** feed the tracker, and record one
  `app.screen.time_to_first_appear` span per screen.

## Setup

```swift
import ScreenInstrumentation
import OpenTelemetrySdk

let tracerProvider = TracerProviderBuilder()
  .with(resource: resource)
  .add(spanProcessor: ScreenSpanProcessor())
  .add(spanProcessor: BatchSpanProcessor(spanExporter: spanExporter))
  .build()
OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)

let loggerProvider = LoggerProviderBuilder()
  .with(resource: resource)
  .with(processors: [
    ScreenLogRecordProcessor(nextProcessor: BatchLogRecordProcessor(logRecordExporter: logExporter))
  ])
  .build()
OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

ScreenInstrumentation.install()
```

Install after registering the providers: `install()` swizzles `UIViewController`, and the first
screen can appear immediately afterwards.

Order the processors so `ScreenSpanProcessor` runs before the exporting processor, and wrap the
exporting log processor in `ScreenLogRecordProcessor`. The attribute must be attached before
batching.

### Configuration

| Field                      | Type     | Description                                                                                       | Default |
| -------------------------- | -------- | ------------------------------------------------------------------------------------------------- | ------- |
| `bundle`                   | `Bundle` | A view controller's class must come from this bundle to be tracked                                | `.main` |
| `tracksUIKitScreens`       | `Bool`   | Detect UIKit screens by swizzling `viewDidLoad` and `viewDidAppear(_:)`                           | `true`  |
| `recordsTimeToFirstAppear` | `Bool`   | Record `app.screen.time_to_first_appear`                                                          | `true`  |
| `tracksHostingControllers` | `Bool`   | Report SwiftUI hosting controllers as UIKit screens, named after the hosting controller's class   | `false` |

```swift
ScreenInstrumentation.install(config: ScreenInstrumentationConfig(
  tracksHostingControllers: true
))
```

## UIKit

Installing exchanges the implementations of `UIViewController.viewDidLoad` and
`UIViewController.viewDidAppear(_:)`. Every view controller in the configured bundle then
reports itself, named after its class.

`viewDidLoad` records when the screen was created. `viewDidAppear(_:)` makes it the current
screen and ends the `app.screen.time_to_first_appear` span.

Swizzling is process-wide and permanent. `install()` does it once; later calls return.

### Naming a screen, or staying out

```swift
final class LoginViewController: UIViewController, ScreenTrackingCustomization {
  var customScreenName: String? { "Login" }
}

final class DebugViewController: UIViewController, ScreenTrackingCustomization {
  var tracksScreen: Bool { false }
}
```

Without the protocol, the class name is the screen name, with the module prefix and any generic
arguments removed. The bundle filter keeps `UINavigationController`, `UITabBarController` and the
frameworks' other plumbing out of the data.

## SwiftUI

```swift
SettingsView()
  .otelScreen("Settings")
```

or, for the wrapper form:

```swift
ScreenTraceView("Settings") {
  SettingsView()
}
```

Apply it to a screen, not to a row or a label: every appearance sets the current screen.

SwiftUI detection is opt-in by design. A SwiftUI screen has no lifecycle method to swizzle, and
reading the view graph to find one means reading SwiftUI's internals. The modifier names the
screen instead. To see SwiftUI screens without touching the views, set
`tracksHostingControllers` and subclass `UIHostingController` per screen; the subclass's name
becomes the screen name.

## What it emits

### Event: `app.navigation.complete`

One per screen change, matching
[`opentelemetry-android`](https://github.com/open-telemetry/opentelemetry-android/blob/main/semconv/model/android/events.yaml),
so one receiver mapping covers both mobile SDKs.

```json
{
  "eventName": "app.navigation.complete",
  "timestamp": 1692123456789000000,
  "attributes": {
    "app.navigation.destination.name": "Comments",
    "app.screen.previous.name": "Stories",
    "app.screen.name": "Comments",
    "app.screen.type": "uikit"
  }
}
```

| Attribute                         | Type   | Description                                       |
| --------------------------------- | ------ | ------------------------------------------------- |
| `app.navigation.destination.name` | string | The screen the navigation reached                 |
| `app.screen.previous.name`        | string | The screen that was visible before, when there was one |
| `app.screen.name`                 | string | Added by `ScreenLogRecordProcessor`               |
| `app.screen.type`                 | string | `uikit` or `swiftui`                              |

Setting the same screen again emits nothing. Coming back to an earlier screen does emit, because
that is a navigation.

### Span: `app.screen.time_to_first_appear`

One per screen instance, measuring creation to first appearance.

- **UIKit** — starts at `viewDidLoad`, ends at `viewDidAppear(_:)`.
- **SwiftUI** — starts when SwiftUI creates the view's state, ends at the first `onAppear`.

| Attribute         | Type   | Description          |
| ----------------- | ------ | -------------------- |
| `app.screen.name` | string | The screen's name    |
| `app.screen.type` | string | `uikit` or `swiftui` |

### Attribute: `app.screen.name`

`ScreenSpanProcessor` sets it when a span starts, so a span that outlives a navigation keeps the
screen that produced it. `ScreenLogRecordProcessor` sets it on emit. Neither overwrites a value
already there: a crash report replayed from the previous run names the screen that crashed, not
the one visible now.

## Semantic conventions

Every name is generated, none is written by hand. `app.screen.name` comes from the upstream
conventions, as `SemanticConventions.App.screenName`. The rest come from this repo's federated
registry, as `FederatedSemanticConventions`, and are defined in
[`model/swift/screen.yaml`](../SemanticConventions/model/swift/screen.yaml) and
[`model/swift/screen-spans.yaml`](../SemanticConventions/model/swift/screen-spans.yaml):

| Name                              | Kind      | Source                                   |
| --------------------------------- | --------- | ---------------------------------------- |
| `app.screen.name`                 | attribute | Upstream semantic conventions            |
| `app.navigation.complete`         | event     | `opentelemetry-android`                  |
| `app.navigation.destination.name` | attribute | `opentelemetry-android`                  |
| `app.screen.previous.name`        | attribute | `opentelemetry-android`                  |
| `app.screen.type`                 | attribute | This registry; no other SDK defines it   |
| `app.screen.time_to_first_appear` | span      | This registry; no other SDK defines it   |

`ScreenConstants` holds only the two instrumentation scopes and the notification name, which are
not semantic conventions.

Upstream deprecated `screen.name` in favour of `app.screen.name`, and Android renamed
`last.screen.name` to `app.screen.previous.name`. This module uses the current names.

## Testing

The UIKit tests drive a real `UIViewController`, so they must run on the main actor. Annotate
each test method with `@MainActor`, never the `XCTestCase` subclass: a class-level `@MainActor`
makes the suite hang after the first test, and `xcodebuild` still exits 0 and prints
`** TEST SUCCEEDED **`. Count the tests it executed rather than reading its exit status. That
is how this suite silently fell from 41 tests to 27 once.

```sh
arch -arm64 swift test --filter Screen            # 33 tests; macOS skips the UIKit suite
arch -arm64 xcodebuild test -scheme opentelemetry-swift-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ScreenTests
                                                  # 47 tests
```

`Tests/IntegrationTests/Assertions/ScreenInstrumentationTests.swift` asserts on the exported
OTLP of the `main` launch, so it checks that these names survive serialization. It needs no
scenario of its own, because a screen appears on every launch.

It covers the SwiftUI path only. Integration test mode runs offline, so the demo app replaces the
stories list with a bare `UIViewController` in a disabled tab and starts on the Settings tab, and
`SettingsHostingController` is excluded as a hosting controller. The UIKit path is covered by the
unit tests, which drive real view controllers. Covering it end to end needs a launch that enables
the home tab and pushes a view controller.

## Known gaps

- **A dismissed sheet leaves the screen behind.** `viewDidAppear(_:)` does not fire on the
  presenting view controller when a `.pageSheet` or `.formSheet` goes away, so the tracker keeps
  reporting the sheet. Tracking `viewDidDisappear` would fix it but needs a stack of visible
  screens, because split views and multiple windows show more than one screen at a time.
- **Work started before a screen appears is attributed to the previous screen.** A request made
  from `viewDidLoad` or `viewWillAppear` carries the screen the user is still looking at. That is
  accurate about what was on screen, and wrong about what caused the request.
- **A subclass that skips `super.viewDidAppear(_:)` is invisible.** The swizzle sits on
  `UIViewController`, so a subclass reaches it through its `super` call.
- **Multiple windows share one current screen.** `app.screen.name` names the screen that appeared
  most recently, not the one the span belongs to.

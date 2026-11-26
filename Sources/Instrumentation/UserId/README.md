# User ID Instrumentation

Status: experimental. `user.id` carries `development` stability upstream, so its meaning can change in any release.

The **`UserIdManager`** class attaches an application-supplied user ID to every span and log record as `user.id`, and restores that ID on the next launch.

The module generates no ID of its own and records nothing until your code calls `setUserId(_:)`. A span takes the ID current when it starts, and a log record takes the ID current when it is emitted, so a signal that began before the call carries no ID.

The following diagram shows when the attribute is attached across three launches.

![A time axis crossing three launches of an app. In the first launch no signal carries user.id until a setUserId call, after which spans and log records carry it; one span that started before the call stays unmarked. The second launch carries the ID from its first signal, restored from UserDefaults. In the third launch a clearUserId call ends the ID, and the signals after it carry none.](img/user-id-lifetime.svg)

## Personal data

This module records an identifier for a person and sends it to your telemetry backend with every span and log record. Enabling it takes on four duties.

<dl>
<dt>Disclosure and consent</dt>
<dd>A notice to users that you collect the ID, and consent where GDPR, CCPA or another law requires it. Apple's App Store privacy details list "User ID" as collected data.</dd>
<dt>An opaque value</dt>
<dd>An internal account number or a salted hash, never an email address, a phone number or a name. The semantic conventions define <code>user.hash</code> for an ID that would otherwise contain confidential information, and the deprecated <code>enduser.id</code> carries a PII warning in the registry that applies equally to <code>user.id</code>.</dd>
<dt>Deletion on request</dt>
<dd>Removal of the ID from the device with <code>clearUserId()</code>, and removal of already-exported signals through your own retention and deletion process. Note that this module cannot reach data your backend has stored.</dd>
<dt>Backend access control</dt>
<dd>Restriction of who can read the telemetry, since anyone who can follows one person across sessions.</dd>
</dl>

## Setup

Register a manager, then add the two processors to the providers you build.

```swift
import UserId
import OpenTelemetrySdk

UserIdManagerProvider.register(userIdManager: UserIdManager())

let tracerProvider = TracerProviderBuilder()
  .add(spanProcessor: UserIdSpanProcessor())
  .build()

let loggerProvider = LoggerProviderBuilder()
  .with(processors: [UserIdLogRecordProcessor(nextProcessor: exportProcessor)])
  .build()
```

Set the ID when the person signs in, and clear it when they sign out or withdraw consent.

```swift
UserIdManagerProvider.getInstance().setUserId("account-1234")
UserIdManagerProvider.getInstance().clearUserId()
```

## Instance methods

<dl>
<dt><code>setUserId(_:)</code></dt>
<dd>Sets the ID attached to signals from this point on, and persists it. A <code>nil</code>, empty or whitespace-only value clears the ID instead.</dd>
<dt><code>clearUserId()</code></dt>
<dd>Removes the ID from memory and from storage, so later signals carry no <code>user.id</code>.</dd>
</dl>

## Attribute

<dl>
<dt><code>user.id</code></dt>
<dd>A string giving the application-supplied identifier for the current person, taken from <code>SemanticConventions.User.id</code> in <code>OpenTelemetryApi</code>. A span or record that already carries the attribute keeps its own value.</dd>
</dl>

With no ID set, both processors pass signals through unchanged.

## Storage

The default store is `UserDefaults`, under the key `opentelemetry.user.id`, and a `UserIdManager` restores the ID when it is created.

`UserDefaults` rather than the Keychain, for three reasons. The application supplies the ID and can set it again at every launch, so persistence saves work rather than keeping a secret. Keychain items survive an uninstall, so a Keychain-backed ID would keep identifying a person who deleted the app, which is a persistent device tracker. `UserDefaults` also needs no entitlement and works in unit tests on every platform the package supports.

<dl>
<dt><code>UserIdPersistence</code></dt>
<dd>A protocol for supplying your own store, passed as <code>UserIdManager(persistence:)</code>. A Keychain conformance suits an app that must share the ID with its extensions.</dd>
</dl>

## Differences from aws-otel-swift

[aws-otel-swift PR 21](https://github.com/aws-observability/aws-otel-swift/pull/21) generates a random UUID on first launch, stores it in `UserDefaults`, and attaches it to every span.

| aws-otel-swift | This module |
| --- | --- |
| Generates an ID for every install, on by default | Generates nothing; the application opts in by setting an ID |
| No way to clear or replace the ID | `setUserId(_:)` replaces it and `clearUserId()` deletes it |
| Spans only | Spans and log records |
| Fixed `UserDefaults` store | `UserDefaults` by default, pluggable through `UserIdPersistence` |

A generated identifier is a device identifier whether or not it is named one, which is why this module records nothing until asked.

## See also

- [Semantic conventions for user attributes](https://opentelemetry.io/docs/specs/semconv/registry/attributes/user/)
- [Apple's App Store privacy details](https://developer.apple.com/app-store/app-privacy-details/)

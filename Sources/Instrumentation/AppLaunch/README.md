# App Launch Instrumentation

Status: experimental. Span and attribute names can change in any release, and this library emits conventions at `development` stability in the [federated registry](../SemanticConventions/model/swift/registry.yaml). Read [Accuracy and limits](docs/accuracy.md) before you rely on the numbers.

The **`MincoreLaunchInstrumentation`** class records how long the app takes to become usable after a user brings it to the foreground. It reports each launch as an `app.start` span and each resume as an `app.resume` span, in the `io.opentelemetry.lifecycle` scope that [OpenTelemetry Android](https://github.com/open-telemetry/opentelemetry-android/tree/main/instrumentation/activity) also uses.

A process records at most one launch, so there is at most one `app.start` span per process. The start types follow Apple's definitions rather than Android's.

![Timeline of the app.start and app.resume spans. One bar spans process start to the first frame displayed. Below it three phase bars divide the same interval: app.start.pre_init ends where the app runs this library's static initializer, app.start.app_init ends at didFinishLaunching, and app.start.render ends at the first frame. app.start.scene_setup sits under app.start.render and starts at UIScene.willConnectNotification. A second row shows a prewarmed launch, whose span starts where app code first ran, with app.start.pre_activation.duration recorded outside it. A third row shows a resume, running from willEnterForeground, or from UIScene.willConnectNotification when the system discarded the scene, to the first frame, with an app.resume.scene_setup child and app.resume.background.duration recorded outside it.](img/app-start-timeline.svg)

## Setup

Install the instrumentation before the app first becomes active. Installing is idempotent and thread-safe, and each span uses the tracer provider registered when the app becomes active.

```swift
import MincoreLaunchInstrumentation

MincoreLaunchInstrumentation.install()
```

To change what the library records, pass a configuration.

```swift
MincoreLaunchInstrumentation.install(
  configuration: AppLaunchInstrumentationConfiguration(
    launchTypes: [.cold, .warm, .resume],
    maxLaunchDuration: 60,
    coldPageInRatio: 0.5
  )
)
```

<dl>
<dt><code>launchTypes</code></dt>
<dd>A set of the start types to record. Defaults to <code>[.cold, .warm, .resume, .prewarmed]</code>. The library still tracks an activation of a type you leave out, so that later ones classify correctly, and records no span for it.</dd>
<dt><code>maxLaunchDuration</code></dt>
<dd>A number of seconds giving the longest launch to record, measured from process start, or from when app code first ran for a prewarmed launch. Defaults to <code>60</code>. The library <a href="docs/lifecycle.md#dropped-starts">drops</a> a longer launch.</dd>
<dt><code>coldPageInRatio</code></dt>
<dd>A number above 0 and at most 1 giving the share of sampled code a launch must page in from disk to count as <code>cold</code>. Defaults to <code>0.5</code>. Note that how high the ratio goes depends on the app, so check the ratios yours reports before changing this.</dd>
</dl>

To see why the library recorded a start, or why it did not, turn on [debug logging](docs/lifecycle.md#debugging).

## `app.start` and `app.resume`

The [federated registry](../SemanticConventions/model/swift/spans.yaml) defines both spans and every attribute they carry. The schema follows W3C `PerformanceNavigationTiming`: a time origin, `xxxStart` and `xxxEnd` timestamps, a `type` and an `activationStart`. Each phase is a child span, because OpenTelemetry is deprecating span events.

An `app.start` span runs from process start to the first frame displayed after the app first becomes active, read with a `CADisplayLink`. A prewarmed launch starts instead at the first timestamp app code recorded, because its process began before the user launched the app.

| Child span              | Parent             | Runs from                                                            | To                                 |
| ----------------------- | ------------------ | -------------------------------------------------------------------- | ---------------------------------- |
| `app.start.pre_init`    | `app.start`        | Process start                                                        | This library's static initializer  |
| `app.start.app_init`    | `app.start`        | This library's static initializer                                    | `didFinishLaunching` end           |
| `app.start.render`      | `app.start`        | `didFinishLaunching` end                                             | End of `app.start`                 |
| `app.start.scene_setup` | `app.start.render` | First scene connecting, or `didFinishLaunching` end if that was later | End of `app.start`                 |

The boundary between `app.start.pre_init` and `app.start.app_init` is one of the app's static initializers. Before it the app is being loaded rather than running: dyld maps the executable, loads the libraries it depends on, binds their symbols, and starts running static initializers. This library stamps the time from its own, so where the split falls follows the link order and marks no step in the app's launch. See [What each phase holds](docs/lifecycle.md#what-each-phase-holds).

Not every type carries every phase. A prewarmed process began before the user launched the app, so it reports the time before that as `app.start.pre_activation.duration` outside the span instead of as a `pre_init` child. A resume has no phases at all, because the app's code was already loaded and its UI already built.

| Duration field                       | `cold` | `warm` | `prewarmed` | `app.resume`       |
| ------------------------------------ | :----: | :----: | :---------: | :----------------: |
| `app.start.pre_activation.duration`  |   —    |   —    |      ✓      |         —          |
| `app.start.pre_init.duration`        |   ✓    |   ✓    |      —      |         —          |
| `app.start.app_init.duration`        |   ✓    |   ✓    |      ✓      |         —          |
| `app.start.render.duration`          |   ✓    |   ✓    |      ✓      |         —          |
| `app.start.scene_setup`              |   ✓    |   ✓    |      ✓      |         —          |
| `app.resume.background.duration`     |   —    |   —    |      —      |         ✓          |
| `app.resume.scene_setup`             |   —    |   —    |      —      | `scene_reconnect`  |

See [What the breakdown means](docs/lifecycle.md#what-the-breakdown-means) for where the time goes in each type.

An `app.resume` span runs from `willEnterForeground`, or from `UIScene.willConnectNotification` when the system discarded the app's scene, to the first frame after the app becomes active. See [When a span is emitted](docs/lifecycle.md) for the lifecycle rules and the cases the library records nothing for.

When the app becomes active and then leaves before its first frame, the span ends at that moment and `app.start.outcome` reads `abandoned`. The `app.start.duration` and `app.resume.duration` histograms record completed starts, in seconds.

## Start types

Apple's [Reducing your app's launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time) calls an activation a _launch_ when the process needs to start, and a _resume_ when the app already had a process alive. A launch is _warm_ when the system still has the app in memory, and _cold_ when it has to _page it in_ from disk.

Apple's wording covers the frameworks and daemons the app depends on, but the sample reaches only the app's own images, so the app's code alone decides the type. See [How the launch type is decided](docs/classification.md).

![Two-part diagram. Part one shows an image's segments — __TEXT, __DATA_CONST, __DATA and __LINKEDIT — with __TEXT highlighted as the only one sampled, because it holds read-only code the kernel discards and re-reads, although a cold launch reads all four from disk, and expands it into a strip of up to 256 evenly spaced sampled pages. Part two shows those pages as cells at two moments, at the library's constructor and when the app became active, for a cold launch and a warm one. In the cold launch 70 pages were already resident and 170 paged in, giving a ratio of 0.71; in the warm launch 233 were already resident and 7 paged in, giving 0.03. A scale at the bottom marks both ratios either side of the 0.5 coldPageInRatio threshold.](img/text-page-sampling.svg)

The `app.start.type` attribute can have the following values, each given with Apple's term for it.

<dl>
<dt><code>cold</code>, Apple's cold launch</dt>
<dd>A new process whose launch read the app's code from disk: its page-in ratio is at least <code>coldPageInRatio</code>.</dd>
<dt><code>warm</code>, Apple's warm launch</dt>
<dd>A new process whose launch found the app's code already in memory: its page-in ratio is below <code>coldPageInRatio</code>.</dd>
<dt><code>prewarmed</code>, Apple's warm launch</dt>
<dd>A new process the system created before the user launched the app. See <a href="docs/classification.md#prewarming">Prewarming</a>.</dd>
</dl>

`resume` is a `launchTypes` option rather than an `app.start.type` value, because a resume becomes an `app.resume` span carrying an `app.resume.type` of its own.

### Resume types

The `app.resume.type` attribute can have the following values. Each describes a process that was already alive, so none of them is a launch.

<dl>
<dt><code>hot</code></dt>
<dd>A return to the foreground with the app's UI still built. This is the ordinary case, and it covers a launch the user left before its first frame, since that launch reached the background with its UI built.</dd>
<dt><code>scene_reconnect</code></dt>
<dd>A return to the foreground after the system discarded the app's scene, so UIKit connects a new one.</dd>
<dt><code>background_launched</code></dt>
<dd>The first time the app reaches the foreground after the system started the process in the background. Note that such a resume has no page baseline, so it reports <code>app.resume.pages.text.total</code> alone.</dd>
</dl>

## Attributes

The [federated registry](../SemanticConventions/model/swift/registry.yaml) defines every attribute below at `development` stability. A child span carries none of them: each phase's duration is copied onto its root span instead, so a query needs no join.

Both spans also carry the following attributes once you register the [Sessions](../Sessions/README.md) span processor.

<dl>
<dt><code>session.id</code></dt>
<dd>A string identifying the session the span belongs to.</dd>
<dt><code>session.previous_id</code></dt>
<dd>A string identifying the session before it, where there was one.</dd>
</dl>

### `app.start`

A launch span carries the following attributes. The `app.start.pages.text` counts come from the page sample, so a launch classified from [launch history](docs/classification.md#launch-history-fallback) reports `app.start.pages.text.total` alone, which the library reads from the binary.

<dl>
<dt><code>app.start.app_init.duration</code></dt>
<dd>A number of seconds giving the duration of the <code>app.start.app_init</code> child span.</dd>
<dt><code>app.start.determined_by</code></dt>
<dd>A string naming what decided <code>app.start.type</code>. Either <code>page_sampling</code>, from the page-in ratio, <code>launch_history</code>, from what changed since the previous launch, or <code>prewarm_flag</code>, from the <code>ActivePrewarm</code> environment variable. See <a href="docs/classification.md">How the launch type is decided</a>.</dd>
<dt><code>app.start.outcome</code></dt>
<dd>A string giving how the launch ended. Either <code>completed</code>, meaning it reached its first frame, or <code>abandoned</code>, meaning the app left the foreground first.</dd>
<dt><code>app.start.page_ins.after_text_sample</code></dt>
<dd>A number of page-ins the whole process took from the page sample's baseline to the end of the span. It covers the window <code>app.start.pages.text.paged_in</code> measures, for the whole process rather than the app's own code, so it is the larger of the two.</dd>
<dt><code>app.start.page_ins.before_text_sample</code></dt>
<dd>A number of page-ins the whole process took from process start to the page sample's baseline, which the library takes before <code>main()</code>. This is the window <code>app.start.pages.text.paged_in</code> cannot see, because a page read in it is already resident in the baseline. Both counts hold page-ins, the faults that read a page from a backing store, and leave out minor faults such as zero-fill and copy-on-write.</dd>
<dt><code>app.start.pages.text.page_in_ratio</code></dt>
<dd>A number from 0 to 1 giving the share of the sampled code the launch paged in from disk: <code>app.start.pages.text.paged_in</code> divided by <code>app.start.pages.text.resident_at_end</code>. A launch is <code>cold</code> when the ratio reaches <code>coldPageInRatio</code>, and this is the measurement behind that verdict, so a consumer that prefers another line can recalculate from it.</dd>
<dt><code>app.start.pages.text.paged_in</code></dt>
<dd>A number of sampled pages that were resident when the app became active but not when this library's initializer ran.</dd>
<dt><code>app.start.pages.text.resident_at_end</code></dt>
<dd>A number of sampled pages of the app's code that were in the system's page cache when the app became active. <code>mincore</code> reports the cache rather than this process, so the count includes pages an earlier launch left and pages the kernel read ahead.</dd>
<dt><code>app.start.pages.text.sampled</code></dt>
<dd>A number of pages of the app's code the launch sampled: up to 256, spread evenly through the <code>__TEXT</code> segments of the app's own images.</dd>
<dt><code>app.start.pages.text.total</code></dt>
<dd>A number of pages of the app's code that could be sampled, whether or not the sample covered them. Against <code>app.start.pages.text.sampled</code> it says what share of the app's code the sample stands for, because the cap covers a large app more thinly than a small one.</dd>
<dt><code>app.start.pre_activation.duration</code></dt>
<dd>A number of seconds giving the time from process start to the moment app code first ran, on a prewarmed launch. The span starts where that time ends, so it is no part of the launch's duration.</dd>
<dt><code>app.start.pre_init.duration</code></dt>
<dd>A number of seconds giving the duration of the <code>app.start.pre_init</code> child span.</dd>
<dt><code>app.start.prewarm.cache_state</code></dt>
<dd>A string giving whether a prewarmed launch still had to bring the app's code into memory. Either <code>cold</code> or <code>warm</code>, by the same comparison that decides a launch's type. It is diagnostic only, and leaves <code>app.start.type</code> at <code>prewarmed</code>.</dd>
<dt><code>app.start.render.duration</code></dt>
<dd>A number of seconds giving the duration of the <code>app.start.render</code> child span.</dd>
<dt><code>app.start.type</code></dt>
<dd>A string giving how the launch began. Either <code>cold</code>, <code>warm</code> or <code>prewarmed</code>, as <a href="#start-types">Start types</a> describes. The <code>app.start.duration</code> histogram carries this attribute too.</dd>
</dl>

### `app.resume`

A resume span carries the following attributes, and none of the launch attributes above, because the process was already running. Every `app.resume.pages.text` count but the total needs the baseline the library takes when the app enters the background.

<dl>
<dt><code>app.resume.background.duration</code></dt>
<dd>A number of seconds giving the time from when the app last entered the background to the start of the resume. Recorded only for a resume the app entered the background before.</dd>
<dt><code>app.resume.outcome</code></dt>
<dd>A string giving how the resume ended. Either <code>completed</code> or <code>abandoned</code>, as <code>app.start.outcome</code> is.</dd>
<dt><code>app.resume.page_ins</code></dt>
<dd>A number of page-ins the whole process took from <code>willEnterForeground</code> to the end of the span, which show what the system reclaimed while the app was suspended. The counter is cumulative for the process, so a count that went backwards means the system reset it and the library reports nothing.</dd>
<dt><code>app.resume.pages.text.page_in_ratio</code></dt>
<dd>A number from 0 to 1 giving <code>app.resume.pages.text.paged_in</code> divided by <code>app.resume.pages.text.resident_at_end</code>.</dd>
<dt><code>app.resume.pages.text.paged_in</code></dt>
<dd>A number of sampled pages that were resident at the end of the resume but not when the app entered the background. It is the difference between two snapshots rather than everything the system reclaimed, so a page reclaimed and read back while the app was away counts for nothing.</dd>
<dt><code>app.resume.pages.text.resident_at_end</code></dt>
<dd>A number of sampled pages of the app's code that were in memory at the end of the resume.</dd>
<dt><code>app.resume.pages.text.sampled</code></dt>
<dd>A number of pages of the app's code the resume sampled, the same pages the launch sampled.</dd>
<dt><code>app.resume.pages.text.total</code></dt>
<dd>A number of pages of the app's code that could be sampled, whether or not the sample covered them. The library reads it from the binary, so it reports it for every resume, including one with no page baseline.</dd>
<dt><code>app.resume.type</code></dt>
<dd>A string giving how much UI the resume had to rebuild. Either <code>hot</code>, <code>scene_reconnect</code> or <code>background_launched</code>, as <a href="#resume-types">Resume types</a> describes. The <code>app.resume.duration</code> histogram carries this attribute too.</dd>
</dl>

## Platform support

| Platform       | Status      | Tested on            | What the library records                                           |
| -------------- | ----------- | -------------------- | ------------------------------------------------------------------ |
| iOS            | Development | Device and simulator | Every type                                                         |
| iPadOS         | Untested    | Neither              | The same as iOS                                                    |
| visionOS       | Untested    | Neither              | Every type, with `prewarmed` only where the system sets `ActivePrewarm` |
| Mac Catalyst   | Untested    | Neither              | The same as visionOS                                               |
| tvOS           | Untested    | Neither              | The same, except that it reads no background launch from the process's role |
| macOS          | Untested    | Neither, and it has no simulator | Launches only, ending at the first `NSApplication.didBecomeActiveNotification`, because macOS has neither `CADisplayLink` nor a background state |
| watchOS        | Unsupported | —                    | Nothing. The API compiles, so shared code needs no check           |
| Linux, Windows | Unsupported | —                    | Nothing. The product is not built, so it cannot be a dependency    |

`Untested` means nobody has collected telemetry from that platform, so the row describes what the code would record. A simulator reads the Mac's page cache, so it exercises the lifecycle but says nothing about `cold` and `warm`, and it cannot produce a `prewarmed` launch: only the device run supports the thresholds. See [What has been verified](docs/accuracy.md#what-has-been-verified).

## See also

- [How the launch type is decided](docs/classification.md): page sampling, the launch history fallback, prewarming, and how the types differ from Android's
- [When a span is emitted](docs/lifecycle.md): resume rules, dropped starts, and debug logging
- [Accuracy and limits](docs/accuracy.md): the comparison with Instruments, what has been verified, known limits, and what is not recorded yet
- [Navigation Timing Level 2](https://www.w3.org/TR/navigation-timing-2/): the W3C `PerformanceNavigationTiming` model this schema follows, for the time origin, the `xxxStart` and `xxxEnd` pairs, `type` and `activationStart`
- [Reducing your app's launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time): Apple's definitions of activation, launch, resume, and cold and warm launches
- [`CADisplayLink`](https://developer.apple.com/documentation/quartzcore/cadisplaylink): how the library reads the first frame, and so where every launch and resume span ends
- [MXAppLaunchMetric](https://developer.apple.com/documentation/metrickit/mxapplaunchmetric): the system's own launch and resume histograms, through the [MetricKit](../MetricKit/README.md) instrumentation
- [OpenTelemetry Android activity instrumentation](https://github.com/open-telemetry/opentelemetry-android/tree/main/instrumentation/activity)

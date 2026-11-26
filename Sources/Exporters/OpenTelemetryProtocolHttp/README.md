# OTLP HTTP exporters: retries and backoff

The trace, log and metric exporters retry a failed export with exponential backoff. The
policy lives in `OtlpRetryPolicy`; pass one through the `retryPolicy:` parameter of any
exporter initializer. The default needs no configuration.

```swift
let exporter = OtlpHttpTraceExporter(
  endpoint: url,
  retryPolicy: OtlpRetryPolicy(maxRetries: 3, initialBackoff: 2, maxPendingSignals: 1024))
```

## How it works

A failed batch returns to the exporter's in-memory queue, as it did before. The exporter now
also records a **not-before time**. A call to `export` that arrives earlier does not send. It
adds its signals to the queue and returns `.failure` at once. The first call after the deadline
sends the oldest `maxExportBatchSize` signals (default 512). Later calls send the rest.

The exporter never sleeps and starts no timer. The batch processor or periodic reader already
calls `export` on a schedule, and that schedule drives the retries. A retry therefore cannot
block the caller's thread, and an app has no retry thread to stop at shutdown.

The delay after the *n*th consecutive failure is `initialBackoff * multiplier^(n-1)`, capped at
`maxBackoff`. The defaults give 1, 2, 4, 8 and 16 seconds. Because retries ride on the caller's
schedule, a retry fires at the first `export` call at or after its deadline, not at the deadline.

A success clears the failure count. After `maxRetries` retries (default 5, so six attempts) the
batch is dropped and the count restarts.

## Which failures retry

The OTLP specification
([Retryable Response Codes](https://github.com/open-telemetry/opentelemetry-proto/blob/main/docs/specification.md#retryable-response-codes))
says:

> The requests that receive a response status code listed in following table SHOULD be retried.
> All other `4xx` or `5xx` response status codes MUST NOT be retried.

The table lists 429, 502, 503 and 504. These are the default `retryableStatusCodes`. Any other
status drops the batch at once, so a `400 Bad Request` no longer circulates in the queue.
`500` is not on the list and does not retry. Widen the set through `OtlpRetryPolicy` if a
collector in front of you returns it for transient faults.

A failure with no HTTP status (the connection dropped, the host was unreachable, the request
timed out) retries. The specification: "If the server disconnects without returning a response,
the client SHOULD retry and send the same request. The client SHOULD implement an exponential
backoff strategy between retries."

### Retry-After

The specification
([OTLP/HTTP Throttling](https://github.com/open-telemetry/opentelemetry-proto/blob/main/docs/specification.md#otlphttp-throttling)):
"The client SHOULD honour the value specified in the "Retry-After" header if it is present."
The exporter reads both forms, a count of seconds and an HTTP-date. The server's value replaces
the exponential delay for that failure, even when it is shorter. `maxRetryAfter` (default 300 s)
caps it, so a bad header cannot idle the exporter for a day.

## Request size

One request carries at most `maxExportBatchSize` signals (default 512, the batch processors'
default export batch size). A queue that grew during an outage therefore leaves in several
requests, not one payload that a hosted backend may refuse. The OTLP specification asks the
client to "limit the size of the request message ... to avoid overwhelming the server" and
recommends 64 MiB as the ceiling. A failed batch returns to the head of the queue.

`413 Payload Too Large` does not retry: waiting does not shrink a request. If a server still
returns it, only that batch of at most 512 signals is dropped, not the queue.

## The queue is bounded

`maxPendingSignals` (default 2048, the batch processors' default queue size) bounds the
queue. When it is full the **oldest signals are discarded** and the newest kept. The exporter
reports each overflow, and each drop after a permanent failure or an exhausted retry limit,
through `OpenTelemetry.instance.feedbackHandler`.

## `forceFlush` and `shutdown`

`flush` and `forceFlush` ignore the backoff. They send the queue batch by batch within the
timeout, which is what a caller who asks for a flush wants. A failed flush starts or extends the
backoff.

`shutdown` makes one last send of the queue, ignoring the backoff. It waits at most
`explicitTimeout`, or `retryPolicy.shutdownTimeout` (default 2 s) when the caller passes none, so a dead
network cannot stall app termination. The batch processors export their final batch before
they call `shutdown`; if that batch lands inside a backoff, `shutdown` still sends it.

## Persistence

With `requeueOnFailure: false` the exporter keeps no queue and applies no backoff. This is the
configuration the Persistence exporter needs; the disk store then owns retry.

## Where jitter would go

Not built. The specification asks for random jitter on connection retries. It belongs in
`OtlpRetryPolicy.delay(afterFailure:retryAfter:)`: multiply the exponential delay by a random
factor in a range such as 0.5 to 1.5, and leave a `Retry-After` value untouched. Take the random
source as a parameter so tests stay deterministic.

## Differences from aws-otel-swift

[aws-otel-swift PR 89](https://github.com/aws-observability/aws-otel-swift/pull/89) retries inside
an `HTTPClient` (`AwsHttpClient`) that sleeps between attempts with `asyncAfter`. This
implementation retries in the exporter's queue instead.

- ADOT's client holds a request open across all its retries (1 + 2 + 4 s with its defaults)
  while the exporter waits on a semaphore for at most the export timeout. The exporter then
  reports failure, and the retries run on unseen. Here the exporter reports each attempt.
- ADOT retries 408, 429, 500, 502, 503, 504 and 509. This follows the OTLP specification:
  429, 502, 503, 504.
- ADOT ignores `Retry-After` and returns `.success` after its last failed attempt, so the
  exporter counts the batch as delivered. Here the batch is dropped and counted as dropped.
- ADOT's retrying client keeps no queue of its own. Here the retry queue is bounded and drops
  the oldest signals.
- ADOT caps the delay at 60 s and the retries at 3. Here the defaults are 60 s and 5.

## Tests

`OtlpHttpRealSocketRetryTests` runs the real exporter and `BaseHTTPClient` against a TCP server
on an ephemeral port, the way a collector would answer. It checks that the server receives every
span exactly once through a 503 outage with `Retry-After`, a four-failure exponential sequence,
a refused connection, a 1500-span queue, a 413, and a `shutdown` inside a 60 s backoff. The
suite takes about 7 s and runs with the rest of `--filter OtlpHttp`. It needs Network.framework,
so it compiles only where `canImport(Network)` holds. Each test prints its request log under the
`RETRYREPORT` prefix.

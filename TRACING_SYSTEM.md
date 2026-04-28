# PM2 Distributed Tracing System

Complete documentation of the OpenTelemetry tracing pipeline from application instrumentation to frontend visualization.

## Architecture Overview

```
App Process          PM2 Daemon          PM2 IO Agent          km-api               Frontend
+-----------+       +----------+        +------------+       +---------+          +----------+
| OTel SDK  |--IPC->| God.bus  |--PUB-->| Push       |--WS-->| Handler |--ES----->| Vue App  |
| BPM       |       | ForkMode |  sock  | Interactor |       | TraceSpan|  bulk   | Zipkin   |
| Zipkin Exp|       | Daemon   |        | Transport  |       | format() |  index  | Waterfall|
+-----------+       +----------+        +------------+       +---------+          +----------+
```

## Phase 1: Trace Generation (App Process)

### Activation

Tracing is activated per-process via `pm2 start app.js --trace` or `trace: true` in ecosystem config.

The `trace` option flows through `Common.js` into `pm2_env`, then becomes `process.env.trace = 'true'` in the child process environment (set by `ForkMode.js:97` which passes `pm2_env` as the spawn env).

### BPM Auto-Injection

**File:** `lib/ProcessContainerFork.js` -> `lib/ProcessUtils.js`

Every PM2-managed process loads the BPM module (`modules/pm2-io-bpm`) on startup. When `process.env.trace === 'true'`:

1. `ProcessUtils.injectModules()` calls `pmx.init({ tracing: true })`
2. `PMX.init()` destroys and recreates the singleton (since BPM already auto-initialized on `require()`)
3. `FeatureManager.init(config)` initializes all features including `TracingFeature`

**File:** `modules/pm2-io-bpm/features/tracing.js`

`TracingFeature.init()` checks `config.tracing`:
- If `false` or `undefined` -> `enabled: false` -> **returns immediately, OTel never loaded**
- If `true` -> `enabled: true` -> proceeds to require and start OTel

When enabled:
```
require('@opentelemetry/sdk-node')                    -> NodeSDK
require('@opentelemetry/auto-instrumentations-node')  -> HTTP auto-instrumentation
require('../otel/custom-zipkin-exporter/zipkin')       -> CustomZipkinExporter
```

The `NodeSDK` starts with:
- Auto-instrumentation for HTTP/HTTPS (DNS, FS, net disabled)
- `CustomZipkinExporter` as the trace exporter
- Service name from `process.env.OTEL_SERVICE_NAME` or PM2 app name

After startup, sends `axm:option:configuration` with `{ otel_tracing: true }` to the daemon.

### Span Export via IPC

**Files:**
- `modules/pm2-io-bpm/otel/custom-zipkin-exporter/zipkin.js`
- `modules/pm2-io-bpm/otel/custom-zipkin-exporter/transform.js`
- `modules/pm2-io-bpm/otel/custom-zipkin-exporter/platform/node/util.js`

When the OTel SDK completes a span:

1. `CustomZipkinExporter.export(spans, callback)` receives a batch of `ReadableSpan` objects
2. `_sendSpans()` transforms each span via `toZipkinSpan()`:
   - `span.spanContext().traceId` -> `traceId`
   - `span.spanContext().spanId` -> `id`
   - `span.parentSpanId` -> `parentId`
   - `span.name` -> `name`
   - `span.kind` -> `kind` (mapped to Zipkin: SERVER, CLIENT, CONSUMER, PRODUCER)
   - `hrTimeToMicroseconds(span.startTime)` -> `timestamp` (microseconds)
   - `hrTimeToMicroseconds(span.duration)` -> `duration` (microseconds)
   - `serviceName` -> `localEndpoint.serviceName`
   - Span attributes + resource attributes -> `tags` (stringified)
3. `prepareSend()` filters and sends each Zipkin span:
   - Drops root CLIENT spans (no parentId) to avoid duplicate outbound traces
   - Drops spans shorter than `MINIMUM_TRACE_DURATION` (0 in test, 1000us in prod)
   - Calls `transport.send('trace-span', span)` for each valid span

**File:** `modules/pm2-io-bpm/transports/IPCTransport.js:87-101`

`IPCTransport.send(channel, payload)` calls:
```javascript
process.send({ type: 'trace-span', data: zipkinSpan })
```

This sends the span over the Node.js IPC file descriptor to the PM2 daemon (parent process).

### Zipkin Span Structure

```javascript
{
  traceId: "5f08ce5b1a2c8b77c839cb1af9e8d657",  // 128-bit hex
  id: "2e076a3f6a828f7a",                          // 64-bit hex
  parentId: "8c36712ffeec6a46",                     // 64-bit hex (or absent for root)
  name: "GET",                                      // operation name
  kind: "SERVER",                                   // SERVER|CLIENT|PRODUCER|CONSUMER
  timestamp: 1774627966453000,                      // start time in microseconds
  duration: 1270,                                   // duration in microseconds
  localEndpoint: {
    serviceName: "my-app"                            // PM2 app name
  },
  tags: {
    "http.url": "http://localhost:3000/api/users",
    "http.method": "GET",
    "http.status_code": "200",
    "http.target": "/api/users",
    "service.name": "my-app",
    "telemetry.sdk.name": "opentelemetry",
    "telemetry.sdk.version": "2.6.1",
    "process.pid": "12345",
    "process.runtime.name": "nodejs",
    // ... resource attributes
  }
}
```

## Phase 2: Daemon Relay

### God.bus Emission

**File:** `lib/God/ForkMode.js:221-237`

The daemon receives IPC messages from child processes:

```javascript
cspr.on('message', function forkMessage(msg) {
  if (msg.data && msg.type) {
    process.nextTick(function() {
      God.bus.emit(msg.type, {       // emits 'trace-span'
        at:      Utility.getDate(),
        data:    msg.data,           // the Zipkin span
        process: {
          pm_id:      cspr.pm2_env.pm_id,
          name:       cspr.pm2_env.name,
          versioning: cspr.pm2_env.versioning,
          namespace:  cspr.pm2_env.namespace
        }
      });
    });
  }
});
```

The same logic exists in `ClusterMode.js` for cluster-mode processes.

### Pub Socket Broadcast

**File:** `lib/Daemon.js:440-450`

The daemon forwards events from God.bus to the pub-emitter socket:

```javascript
God.bus.onAny(function(event, data_v) {
  if (['axm:action',
       'axm:monitor',
       'axm:option:setPID',
       'axm:option:configuration'].indexOf(event) > -1) {
    return false;  // filtered out, not broadcast
  }
  that.pub.emit(event, Utility.clone(data_v));
});
```

`trace-span` is **not** in the filter list, so it is broadcast on the pub socket (`~/.pm2/pub.sock`).

Note: `axm:option:configuration` IS filtered — the `otel_tracing: true` flag is stored internally by the daemon in `pm2_env.axm_options` but never reaches the pub socket.

## Phase 3: PM2 IO Agent

### Event Subscription

**File:** `modules/pm2-io-agent/src/push/PushInteractor.js:54`

The agent subscribes to all PM2 pub socket events:

```javascript
this._ipm2.bus.on('*', this._onPM2Event.bind(this))
```

### Event Routing

**File:** `modules/pm2-io-agent/src/push/PushInteractor.js:77-137`

The `_onPM2Event` handler routes events:

```javascript
_onPM2Event (event, packet) {
  // ... validation, process normalization ...

  packet.process = {
    pm_id:  packet.process.pm_id,
    name:   packet.process.name,
    rev:    packet.process.rev || versioning_revision,
    server: this.opts.MACHINE_NAME
  };

  // Legacy path: 'axm:trace' events go to aggregator (broken pipeline)
  if (event.indexOf('axm:trace') > -1)
    return this.aggregator.aggregate(packet);

  // All other events (including 'trace-span') sent directly
  return this.transport.send(event, packet);
}
```

**Important:** `trace-span` does NOT match `'axm:trace'`, so it bypasses the TransactionAggregator and is sent directly to the backend via WebSocket as-is.

### WebSocket Transport

**File:** `modules/pm2-io-agent/src/transporters/WebsocketTransport.js:112-178`

The transport sends the packet:

```javascript
let packet = {
  payload: data,           // { at, data: zipkinSpan, process: {pm_id, name, rev, server} }
  channel: 'trace-span'   // preserved from the original event name
};
this._ws.send(JSON.stringify(packet));
```

Headers include: `X-KM-PUBLIC`, `X-KM-SECRET`, `X-KM-SERVER`, `X-PM2-VERSION`.

## Phase 4: km-api Backend

### WebSocket Handler

**File:** `km-api/src/proxy/handler.js:143-202`

The WebSocket handler receives the packet:

1. Parses JSON: `{ payload, channel: 'trace-span', server_name }`
2. Looks up bucket from `X-KM-PUBLIC` header
3. Validates bucket auth against `X-KM-SECRET`
4. Checks plan: **free tier drops all data** (`if (planName === 'free') return null`)
5. Calls `_format('trace-span', payload, meta, callback)` to validate/enrich
6. Calls `directInjection('trace-span', packet, privateKey)` to store

### Data Type Dispatch

**File:** `km-api/src/shared/lib/modular.js`

The modular system routes `trace-span` channel to `TraceSpan` data type:

```javascript
Modular.getFromChannel('trace-span')
// Returns: { incoming: 'trace-span', name: 'trace_span', module: TraceSpan }
```

### TraceSpan Format

**File:** `km-api/src/shared/data_types/TraceSpan.js:416-478`

`TraceSpan.format()` validates and enriches each span:

1. **ACL check**: Verifies `distributedTracing` feature is enabled for the bucket
2. **Unwrap**: Extracts span from PM2 wrapper (`payload.data` -> actual Zipkin span)
3. **Defaults**: Sets missing fields:
   - `at`: current timestamp
   - `parentId`: `'NULL'` if absent (marks root spans)
   - `annotations`: `[]`
   - `debug`: `false`
   - `shared`: `false`
   - `localEndpoint`/`remoteEndpoint`: `{}`
   - `name`: `'unknown'`
   - `kind`: `''`
4. **Searchable tags**: Builds `_q` array from tags for full-text search:
   ```javascript
   _q: ["http.method", "http.method=GET", "http.status_code", "http.status_code=200", ...]
   ```
5. **Attaches process metadata**: `process: { name, server, rev, pm_id }`
6. **Schema validation**: Validates against Elasticsearch mapping

### TraceSpan Save

**File:** `km-api/src/shared/data_types/TraceSpan.js:486-501`

`TraceSpan.save()` pushes spans to Elasticsearch:

```javascript
static save (data, meta) {
  for (let span of data) {
    ESBulker.push(meta.bucket.es_cluster, {
      index: { _index: bucketIndex, _type: 'trace-span' }
    }, span);
  }
}
```

Index name pattern: `{secret_id}_{YYYY.MM.DD}`

### Elasticsearch Mapping

**File:** `km-api/src/shared/data_types/mappings/v5/trace-span.js`

```
at                              date
traceId                         keyword
name                            keyword
parentId                        keyword (null_value: 'NULL')
id                              keyword
kind                            keyword
timestamp                       long (microseconds)
duration                        long (microseconds)
debug                           boolean
shared                          boolean
localEndpoint.serviceName       keyword
localEndpoint.ipv4              keyword
localEndpoint.ipv6              keyword
localEndpoint.port              integer
remoteEndpoint                  (same structure)
annotations[].timestamp         long
annotations[].value             keyword
tags                            object (dynamic: strict, enabled: false)
_q                              keyword (searchable tag array)
process.name                    keyword
process.server                  keyword
process.rev                     keyword
process.pm_id                   integer
```

### Alternative Ingestion: Zipkin Collector

**File:** `km-api/src/zipkin-collector/collector.js`

A standalone HTTP endpoint accepts standard Zipkin format:

- `POST /api/v2/spans` — Zipkin v2 JSON or Thrift
- `POST /api/v1/spans` — Zipkin v1 Thrift

Auth: `Authorization: Basic base64(public:secret)`

Flow: Parse -> Auth -> `TraceSpan.format()` -> `RedisPusher.push('trace-span', span, bucketId)`

This allows external Zipkin-compatible services to send traces directly.

## Phase 5: Query Endpoints

**File:** `km-api/src/api/controllers/data/traces.controller.js`

Base path: `/api/bucket/:id/data/traces`

### List Traces

`POST /` — Returns paginated trace list with filtering.

**Query parameters:**
- `start`, `end` — time range (ISO timestamps)
- `serviceName` — filter by service
- `spanName` — filter by span name
- `kind` — filter by span kind
- `minDuration`, `maxDuration` — duration range (microseconds)
- `tags` — tag key=value filters (matched against `_q` field)
- `limit` — max traces to return
- `includeSpans` — whether to include child spans

**Two-query strategy (includeSpans: false):**
1. Query root spans (`parentId: 'NULL'`) with filters, sorted by timestamp desc
2. For each root span's traceId, aggregate all child spans

**Response:**
```javascript
[
  {
    id: "traceId",
    root: { /* root span */ },
    spans: [ /* child spans (if includeSpans) */ ]
  }
]
```

### Get Single Trace

`GET /:traceId` — Returns all spans for a trace, sorted by timestamp ascending (max 1000 spans).

### Services

`GET /services` — Returns distinct `localEndpoint.serviceName` values from the last 24h.

### Tags

`GET /tags` — Returns distinct tag keys with document counts.

### Histograms

`POST /histogram/tag` — Time-series histogram of a tag value over a date range. Used for statistics display.

`POST /aggregation/tag` — Aggregated counts per tag value.

`POST /aggregation/duration` — Duration statistics (min, max, avg, stddev).

## Phase 6: Frontend Display

**Location:** `pm2-io-frontend/src/components/pages/DistributedTracingPage/`

### Trace List View

**Component:** `DistributedTracingPage/index.vue`

- Calls `FETCH_TRACES` Vuex action -> `km.data.traces.list(bucketId, { includeSpans: false })`
- Displays filter controls: date range, service name, span name, tags
- Shows list of traces with duration bar charts
- Sidebar shows services and tag filters

### Trace Detail View

**Component:** `DistributedTracingPage/Trace/index.vue`

On trace selection:
1. Calls `FETCH_TRACE` -> `km.data.traces.retrieve(bucketId, traceId)`
2. Receives flat array of spans
3. Processes through Zipkin utilities (see below)
4. Renders waterfall timeline

**Summary header shows:**
- Total trace duration
- Start timestamp
- HTTP method and status code (from root span tags)
- Services involved
- Span count

### Span Tree (Waterfall)

**Component:** `DistributedTracingPage/Trace/SpanTree.vue`

Recursive tree renderer:
- Each span = row with indentation based on parent-child depth
- Duration bar: positioned relative to trace start, width proportional to duration
- Color-coded per service name
- Expandable/collapsible child spans
- Click opens `SpanDetails` modal showing annotations, tags, endpoints

### Trace Processing Utilities

**File:** `pm2-io-frontend/src/utils/zipkin/`

**span-node.js — Tree Builder:**
```
Input: [flat span array from API]
  -> SpanNodeBuilder.build(spans)
  -> Index spans by (id, shared, endpoint)
  -> Build parent-child relationships via parentId
  -> Handle shared spans (client+server using same spanId)
  -> Output: SpanNode tree
```

**trace.js — Layout Calculator:**
```
Input: SpanNode tree
  -> treeCorrectedForClockSkew(root)  // adjust for distributed clocks
  -> detailedTraceSummary(root)
  -> Traverse tree breadth-first
  -> Merge spans with same ID (shared)
  -> Calculate positions as % of trace duration
  -> Output: modelview with layout data
```

**span-row.js — Row Renderer:**
```
Input: merged span data
  -> newSpanRow(span)
  -> Extract annotations (cs, sr, ss, cr -> Client/Server Start/Finish)
  -> Derive span kind from annotations or explicit field
  -> Build tag display rows
  -> Detect error type (critical vs transient)
  -> Output: renderable span row
```

**Final modelview structure:**
```javascript
{
  traceId: "abc123",
  duration: 150000,           // total trace duration (us)
  durationStr: "150ms",
  depth: 4,                   // max tree depth
  serviceNameAndSpanCounts: [
    { serviceName: "api-gateway", spanCount: 3 },
    { serviceName: "user-service", spanCount: 5 }
  ],
  timeMarkers: [              // axis labels
    { index: 0, time: "0ms" },
    { index: 1, time: "30ms" },
    // ...
  ],
  spans: [
    {
      spanId: "abc",
      spanName: "GET /api/users",
      serviceName: "api-gateway",
      timestamp: 1774627966453000,
      duration: 150000,
      durationStr: "150ms",
      left: 0,               // % offset from trace start
      width: 100,            // % of trace duration
      depth: 0,              // nesting level
      parentId: null,
      childIds: ["def", "ghi"],
      annotations: [
        { value: "Server Start", timestamp: 1774627966453000, relativeTime: "0ms" }
      ],
      tags: [
        { key: "http.method", value: "GET" },
        { key: "http.status_code", value: "200" }
      ],
      errorType: "none"      // "none" | "transient" | "critical"
    },
    // ... more spans
  ]
}
```

## Known Issues

### Legacy Pipeline (axm:trace -> axm:transaction)

The old tracing system used a different event flow:

1. BPM sent `axm:trace` events (pre-OTel format with `spans[]`, `traceId`, `projectId`)
2. PM2 IO Agent `TransactionAggregator` consumed these, destroying individual span data
3. Aggregated statistics were sent on `axm:transaction` channel
4. km-api `Tracing.js` handled `axm:transaction` — **now disabled** (`format()` returns `Error('Dropped.')`)

This legacy pipeline is non-functional. The current OTel-based `trace-span` pipeline bypasses it entirely.

### Event Name Routing

The PM2 IO Agent routes events based on name matching:

```javascript
if (event.indexOf('axm:trace') > -1) return this.aggregator.aggregate(packet);
return this.transport.send(event, packet);
```

- `axm:trace` -> aggregator (legacy, broken)
- `trace-span` -> sent directly to backend (current, working)

The `trace-span` event name does NOT match `'axm:trace'`, so it correctly bypasses the aggregator.

### Free Tier

km-api `handler.js:185` drops all data for free-tier buckets:
```javascript
if (planName === 'free') return null
```

Traces are only stored for paid plans.

### ACL Gating

`TraceSpan.format()` checks the `distributedTracing` feature flag:
```javascript
if (!Acl.isFeatureAccessible(meta.bucket, 'tracing')) {
  return cb(new Error('Feature not available'))
}
```

The bucket must have distributed tracing enabled in its plan.

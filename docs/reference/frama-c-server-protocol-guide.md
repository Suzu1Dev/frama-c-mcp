# Frama-C Server Protocol — Developer Reference Manual

> **Applicable version**: Frama-C 31.0 (Gallium), re-checked against 33.0
> (Arsenic) on 2026-08-07. The protocol mechanics in sections 1 to 6 are
> unchanged and are exercised against 33.0 by this repository's test suites on
> every run. Request names in section 7 are NOT all stable across versions; the
> known differences are marked inline.
>
> To regenerate the authoritative request list for an installed Frama-C:
>
> ```bash
> frama-c -server-doc /tmp/serverdoc   # markdown, one file per plug-in
> ```
>
> **Original verification**: 2026-02-20, Unix Socket actual measurement plus
> Frama-C/Ivette source code audit
>
> This document is a Frama-C Server protocol reference distilled from actual development, covering protocol specifications, API listings, and key pitfalls in implementation. Suitable for any client project that needs to communicate with Frama-C Server.
>
> **Note**: This article describes the server protocol and startup method of **Frama-C itself** (including manual `-server-socket`, `-server-zmq` and other options) for protocol layer reference. **You do not need to manually start Frama-C when using the MCP server of this repository** - it will pull up automatically (see [README](../../README.md)).

---

## Table of contents

1. [Transmission and Framing](#1-Transmission and Framing)
2. [Command and response format](#2-Command and response format)
3. [Request processing model](#3-Request processing model) ★ Core
4. [Connection life cycle](#4-Connection life cycle)
5. [Incremental Fetch Protocol](#5-Incremental-fetch-Protocol) ★ Important
6. [Marker system](#6-marker-system) ★ Important
7. [API List](#7-api-list)
8. [Key pitfalls and precautions](#8-Key pitfalls and precautions) ★ Must read
9. [Reference Implementation Pattern](#9-Reference Implementation Pattern)
10. [Source code reference](#10-Source code reference)

---

## 1. Transmission and Framing

### 1.1 Transmission method

| Method | Startup Parameters | Description |
|------|---------|------|
| Unix Socket | `-server-socket <path>` | Recommended, supports interactive long connections |
| Batch mode | `-server-batch <file>` | Read commands from the file and execute them all at once |
| ZMQ | `-server-zmq <endpoint>` | Some dispatchs do not compile ZMQ support |

The upper layer protocols of each transmission method are exactly the same.

### 1.2 Frame format

Each message consists of **length prefix + JSON payload**:

| prefix | format | maximum payload | example |
|------|------|---------|------|
| `S` | `S` + 3 lowercase hexadecimal digits | 4095 bytes | `S01a{"cmd":"GET",...}` |
| `L` | `L` + 7 digits lowercase hexadecimal | 268 MB | `L000001a{"cmd":"GET",...}` |
| `W` | `W` + 15 lowercase hexadecimal digits | Theoretically unlimited | Rarely used |

**Encoding rules** (refer to `server_socket.ml:135-139`):
- Payload ≤ 4095 bytes: use `S` prefix, `sprintf "S%03x"`
- Payload ≤ 268435455 bytes: use `L` prefix, `sprintf "L%07x"`
- Otherwise: use `W` prefix, `sprintf "W%015x"`
- Hexadecimal is **lowercase** (OCaml `%x` format)

**Decoding**: First read 1 byte to determine the prefix type, then read the hexadecimal length of the corresponding number of digits, and finally read the JSON string of the specified length.

---

## 2. Command and response format

### 2.1 Command (Client → Server)

```json
// GET — synchronous query
{"cmd":"GET", "id":"RQ.0", "request":"kernel.ast.getFiles", "data":null}

// SET — modify configuration/status
{"cmd":"SET", "id":"RQ.1", "request":"plugins.wp.setTimeout", "data":10}

// EXEC — asynchronous execution (long operation)
{"cmd":"EXEC", "id":"RQ.2", "request":"plugins.eva.analysis.compute", "data":null}

// POLL — Poll queued results (no id required)
"POLL"

// KILL — Cancel an asynchronous operation
{"cmd":"KILL", "id":"RQ.2"}

// SHUTDOWN — Shut down the server process
"SHUTDOWN"

// SIGON/SIGOFF — Signal subscription (advanced usage, generally not needed)
{"cmd":"SIGON", "id":"SIG.0", "request":"kernel.ast.signalFunctions"}
{"cmd":"SIGOFF", "id":"SIG.0", "request":"kernel.ast.signalFunctions"}
```

**Notice**:
- `id` is assigned by the client, an arbitrary string, used to match responses
- `POLL` and `SHUTDOWN` are plain JSON strings (not objects)
- The `id` of KILL must be the same as the `id` of the EXEC to be canceled

### 2.2 Response (Server → Client)

```json
// DATA — Return successfully
{"res":"DATA", "id":"RQ.0", "data":["/tmp/test.c"]}

// ERROR — An error occurred during the request execution
{"res":"ERROR", "id":"RQ.1", "msg":"Expected int, got null: null"}

// REJECTED — request name does not exist
{"res":"REJECTED", "id":"RQ.2"}

// SIGNAL — EXEC intermediate signal (indicating that it is still executing)
{"res":"SIGNAL", "id":"RQ.2"}

// KILLED — EXEC was canceled
{"res":"KILLED", "id":"RQ.2"}

// CMDLINEON — The server is processing command line parameters
"CMDLINEON"

// CMDLINEOFF — The command line is processed and the server is ready
"CMDLINEOFF"
```

**NOTE**: `CMDLINEON`/`CMDLINEOFF` are pure JSON strings.

---

## 3. Request processing model ★

This is the most error-prone part. Frama-C Server has two request processing modes:

### 3.1 Immediate execution (GET)

```
Client → GET → Server processing immediately → DATA/ERROR response
```

- GET requests **do not enter the queue**, are processed and returned immediately
- GET can be processed even if there is an EXEC running
- After the client sends GET, the next message must be the corresponding DATA/ERROR/REJECTED

### 3.2 Queued execution (SET and EXEC)

```
Client → SET/EXEC → Server put into command queue
Client → POLL → Server processing queue → response
Client → POLL → Server processing queue → response
...
```

- **SET and EXEC both enter the command queue** and will not be executed immediately
- The server only processes commands in the queue when it receives `POLL`
- POLL must be sent continuously until a DATA/ERROR/REJECTED/KILLED response is received for the request

> **⚠ Key Trap**: Many developers mistakenly believe that SET is synchronous (wait for DATA after sending). In fact, SET and EXEC are exactly the same and both require POLL driver. If POLL is not sent, the SET request will never be processed and the client will wait until it times out.

### 3.3 Detailed explanation of POLL mechanism

```
Recommended implementation (pseudocode):

function poll_loop(request_id, timeout):
    deadline = now() + timeout

    // First check if there is an immediate response (quick operations may be completed immediately)
    resp = recv(500ms)
    if resp.id == request_id and resp is DATA/ERROR/REJECTED:
        return resp

    while now() < deadline:
        sleep(100ms)
        send("POLL")
        resp = recv(500ms)
        match resp:
            DATA/ERROR/KILLED {id == request_id} → return resp
            SIGNAL → continue // Still executing
            None → continue // No messages to be sent
            Other → discard (possibly a stale response)

    // Timeout, send KILL to cancel
    send(KILL{id: request_id})
    return TimeoutError
```

**POLL interval**: 100ms recommended (Ivette defaults to 50ms).

### 3.4 Response ID matching ★

> **⚠ Key Trap**: You must verify whether the `id` field of the response matches the current request.

Scenario: If the previous SET request times out and is KILLed, residual responses may be returned in subsequent requests. Failure to verify the ID results in:
- Received DATA from the previous request and mistakenly thought it was the response of the current request
- The data type is completely wrong, resulting in parsing failure or logic error

**Correct approach**:
```
function wait_for_id(request_id, timeout):
    loop:
        resp = recv(timeout)
        if resp.id == request_id:
            return resp // Match, return
        else:
            log_warn("Discard stale response id={}", resp.id)
            continue // No match, discard and continue etc.
```

---

## 4. Connection life cycle

### 4.1 Startup and handshake

```
1. Start Frama-C Server:
   frama-c <c_files> -server-socket /tmp/frama-c.sock

2. Client connects to Unix Socket

3. Wait for the handshake to complete:
   Server → "CMDLINEON" // May appear (if there are command line parameters to be processed)
   Server → "CMDLINEOFF" // ready signal
```

**Implementation Notes**:
- Frama-C Server will not actively push messages - the client needs to send a GET request first to trigger the server to send the queued CMDLINEON/CMDLINEOFF
- It is recommended to send a probe GET (such as `getFiles`) immediately after connecting, and then wait for CMDLINEOFF in the read loop
- Recommended timeout of 30 seconds (command line processing may include analysis operations)

### 4.2 Single client limit

Frama-C Server **only accepts one client connection at the same time**. The second client's connection blocks until the first one is disconnected.

### 4.3 Close

Sending the `"SHUTDOWN"` command will **terminate** the Frama-C Server process** (not just disconnect). If you just want to disconnect and keep the server, just close the Socket.

---

## 5. Incremental Fetch Protocol ★

Frama-C Server's Array API (such as `fetchFunctions`, `fetchStatus`) uses incremental paging mode.

### 5.1 Basic process

```json
//Request: data parameter is batch capacity (the maximum number of items returned at one time)
{"cmd":"GET", "id":"RQ.0", "request":"kernel.ast.fetchFunctions", "data":20000}

// response
{"res":"DATA", "id":"RQ.0", "data":{
  "reload": false, // true = Server data has been reset, clear client cache
  "updated": [{...}, ...], // New/updated entries in this batch
  "removed": [], // Entries deleted in this batch (used during incremental updates)
  "pending": 5 // Number of remaining items that have not been returned
}}
```

### 5.2 Complete acquisition algorithm

```
function fetch_all(request_name):
    all_entries = []
    loop:
        resp = GET(request_name, 20000)  // batch capacity = 20000
        if resp.data.reload == true:
            all_entries.clear() //Reset server data and discard previously accumulated data
        all_entries.extend(resp.data.updated)
        if resp.data.pending == 0:
            break
    return all_entries
```

### 5.3 Incremental consumption semantics ★

> **⚠ Key trap**: `fetchX` data can only be consumed once**. The first call returns all entries, the second call returns nothing (`updated: []`, `pending: 0`).

If you need to re-obtain all data, you must call `reloadX` first:

```
GET("kernel.ast.reloadFunctions", null) //Reset the incremental cursor
GET("kernel.ast.fetchFunctions", 20000) // Now returns all data
```

**Corresponding reload request**:

| Fetch request | Reload request |
|-----------|------------|
| `kernel.ast.fetchFunctions` | `kernel.ast.reloadFunctions` |
| `kernel.ast.fetchGlobals` | `kernel.ast.reloadGlobals` |
| `kernel.properties.fetchStatus` | `kernel.properties.reloadStatus` |
| `plugins.wp.fetchGoals` | `plugins.wp.reloadGoals` |
| `plugins.eva.analysis.fetchFunctions` | `plugins.eva.analysis.reloadFunctions` |

### 5.4 Data parameters

The `data` argument to `fetchX` is the **batch capacity** (an integer), not a page number or offset. Indicates the maximum number of items returned by this call. It is recommended to use 20000 (consistent with Ivette client).

---

## 6. Marker system ★

Frama-C Server uses **marker** as the global identifier for AST nodes. Most APIs accept markers as parameters, not function names or file paths.

### 6.1 Marker type

| Prefix | Type | Meaning | Example |
|------|------|------|------|
| `#F` | AST.Decl (function declaration) | Function declaration node | `#F24` |
| `#v` | AST.Marker(PVDecl, variable declaration) | Function as variable | `#v24` |
| `#s` | AST.Marker (statement) | Statement node | `#s2` |
| `#k` | AST.Marker(kinstr) | Instruction node | `#k13` |
| `#p` | AST.Marker(property) | ACSL properties | `#p3` |
| `kf#` | Function key (internal identifier) ​​| fetchFunctions return | `kf#24` |

### 6.2 Marker registration mechanism ★

> **⚠ Key trap**: Markers must first be **registered** in the server's marker table before they can be accepted. Unregistered markers will return an "invalid marker" error.

Registration method: Calling `printDeclaration` will trigger the server to parse the function declaration, and at the same time register the markers of all statements and expressions in the function body to the marker table.

```
// Register the marker first (declared through the print function)
GET("kernel.ast.printDeclaration", "#F24")

//The marker in the function body can only be used after registration.
GET("plugins.eva.values.getValues", {"target": "#s2"})
```

### 6.3 Marker conversion

`#F` (AST.Decl) and `#v` (AST.Marker/PVDecl) use the same numeric suffix (both CIL `varinfo.vid`), but have different semantics:

- `#F24`: Function declaration, used for `printDeclaration`, `scope` filtering, etc.
- `#v24`: Variable declaration marker, used for `startProofs` and other APIs that require AST.Marker

**Conversion**: `#F<vid>` ↔ `#v<vid>`, just replace the prefix.

### 6.4 Data structure returned by `fetchFunctions`

```json
{
  "name": "abs_val", // function name
  "key": "kf#24", // function internal key
  "decl": "#F24", // statement marker (AST.Decl)
  "signature": "int abs_val(int x);", // Function signature
  "sloc": { // Source code location
    "file": "/path/to/file.c",
    "dir": "/path/to",
    "base": "file.c",
    "line": 6
  }
}
```

**NOTE**: File and line numbers are in nested `sloc` objects (not top-level fields).

---

## 7. API List

### 7.1 Request naming rules

| Source | Format | Example |
|------|------|------|
| Kernel (no name) | `kernel.<name>` | — |
| Kernel (name="X") | `kernel.X.<name>` | `kernel.ast.getFiles` |
| Plugin (no name) | `plugins.<plugin>.<name>` | `plugins.callgraph.compute` |
| Plugin (name="X") | `plugins.<plugin>.X.<name>` | `plugins.eva.values.getValues` |

### 7.2 Automatically generated Request

The Frama-C framework automatically generates requests for registered State/Array:

| Registration method | Generated Request |
|----------|---------------|
| `register_state ~name:"X"` | `getX` (GET), `setX` (SET) |
| `register_value ~name:"X"` | `getX` (GET) |
| `register_array ~name:"X"` | `fetchX` (GET paging), `reloadX` (GET) |

### 7.3 Kernel AST

| Request | Kind | Parameters | Return |
|---------|------|------|------|
| `kernel.ast.compute` | EXEC | `null` | `null` (triggers AST rebuild) |
| `kernel.ast.getFiles` | GET | `null` | `["/path/to/file.c", ...]` |
| `kernel.ast.setFiles` | SET | `["/path/to/file.c"]` | — |
| `kernel.ast.getFunctions` | GET | `null` | `["#F24", "#F31", ...]` (marker list) |
| `kernel.ast.getMainFunction` | GET | `null` | `"#F36"` |
| `kernel.ast.fetchFunctions` | GET | `20000` (capacity) | Paginated results (see §5) |
| `kernel.ast.reloadFunctions` | GET | `null` | `null` |
| `kernel.ast.fetchGlobals` | GET | `20000` | Paginated results |
| `kernel.ast.reloadGlobals` | GET | `null` | `null` |
| `kernel.ast.printDeclaration` | GET | `"#F24"` (marker string) | ACSL-annotated declaration AST |
| `kernel.ast.getMarkerAt` | GET | `{file, line, column}` | marker |
| `kernel.ast.getInformation` | GET | `null` | List of information types |

### 7.4 Kernel Properties

| Request | Kind | Parameters | Return |
|---------|------|------|------|
| `kernel.properties.fetchStatus` | GET | `20000` | Paginated property list |
| `kernel.properties.reloadStatus` | GET | `null` | `null` |
| `kernel.properties.propKindTags` | GET | `null` | Property type enum |
| `kernel.properties.propStatusTags` | GET | `null` | Validation status enumeration |
| `kernel.properties.alarmsTags` | GET | `null` | Alarm type enum |

**Attribute structure returned by `fetchStatus`**:
```json
{
  "key": "ip#5",
  "kind": "ensures",             // "requires", "ensures", "behavior", "instance", "exits", "terminates"
  "status": "valid",             // "valid", "unknown", "invalid", "never_tried"
  "scope": "#F24", // declaration marker of the function to which it belongs
  "descr": "ensures abs_val ≥ 0",
  "predicate": "\\result ≥ 0",
  "source": {"file": "...", "line": 10, "dir": "...", "base": "..."},
  "alarm": false,
  "alarm_descr": "",
  "from_libc": false,
  "names": [],
  "kinstr": null
}
```

### 7.5 Kernel Services

| Request | Kind | Parameters | Return |
|---------|------|------|------|
| `kernel.services.getConfig` | GET | `null` | `{version, codename, datadir, ...}` |
| `kernel.services.load` | SET | file path | — |
| `kernel.services.save` | SET | file path | — |
| `kernel.services.getLogs` | GET | `null` | Recent logs (up to 100) |

### 7.6 EVA General

| Request | Kind | Parameters | Return |
|---------|------|------|------|
> **Version note**: 31.0 grouped these under `plugins.eva.general`. 33.0 splits
> them across `analysis`, `stats`, `ast` and `values`, and rejects the `general`
> names outright. This client tries the 33.0 name first and falls back, so both
> work; a new client should use the 33.0 spelling.

| `plugins.eva.analysis.compute` | EXEC | `null` | `null` (run EVA analysis) |
| `plugins.eva.analysis.abort` | GET | `null` | — |
| `plugins.eva.analysis.getComputationState` | GET | `null` | `"computed"` / `"not_computed"` / ... |
| `plugins.eva.stats.getProgramStats` | GET | `null` | Analysis statistics object |
| `plugins.eva.ast.getCallers` | GET | declare marker | caller list |
| `plugins.eva.ast.getCallees` | GET | marker | callee list |
| `plugins.eva.ast.getDeadCode` | GET | Declaration marker | Dead code information |
| `plugins.eva.analysis.fetchFunctions` | GET | `20000` | Function + EVA analysis status |
| `plugins.eva.analysis.fetchProperties` | GET | `20000` | Properties + Priority + Taint |

### 7.7 EVA Values

| Request | Kind | Parameters | Return |
|---------|------|------|------|
| `plugins.eva.values.getValues` | GET | `{"target": "#s2"}` | Value domain information |
| `plugins.eva.values.getCallstacks` | GET | marker | call stack list |
| `plugins.eva.values.getCallstackInfo` | GET | Call stack index | Call stack details |

**`getValues` returns example**:
```json
{
  "vBefore": {"alarms": [], "pointedVars": [], "value": "{1}"},
  "vThen":   {"alarms": [], "pointedVars": [], "value": "{1}"},
  "vElse":   {"alarms": [], "pointedVars": [], "value": "Unreachable"}
}
```

### 7.8 WP

| Request | Kind | Parameters | Return |
|---------|------|------|------|
| `plugins.wp.startProofs` | EXEC | `"#v24"` (PVDecl marker) | `null` |
| `plugins.wp.getScheduledTasks` | GET | `null` | `{active, done, procs, todo}` |
| `plugins.wp.getProvers` | GET | `null` | `["Alt-Ergo:2.6.2"]` |
| `plugins.wp.setProvers` | SET | `["Alt-Ergo"]` | 31.0 only. **Rejected on 33.0**, which documents `setProverState` instead. |
| `plugins.wp.getTimeout` | GET | `null` | `10` |
| `plugins.wp.setTimeout` | SET | `10` | — |
| `plugins.wp.fetchGoals` | GET | `20000` | Paging proof goals |
| `plugins.wp.reloadGoals` | GET | `null` | `null` |
| `plugins.wp.generateRTEGuards` | EXEC | — | Generate RTE assertions |
| `plugins.wp.cancelProofTasks` | SET | — | Cancel proof tasks |

### 7.9 Callgraph

| Request | Kind | Parameters | Return |
|---------|------|------|------|
| `plugins.callgraph.compute` | EXEC | `null` | `null` |
| `plugins.callgraph.getCallgraph` | GET | `null` | `{edges: [...], vertices: [...]}` |
| `plugins.callgraph.getIsComputed` | GET | `null` | `true/false` |

**`getCallgraph` returns example**:
```json
{
  "edges": [
    {"src": "#F36", "dst": "#F24", "kind": "both"},
    {"src": "#F36", "dst": "#F31", "kind": "both"}
  ],
  "vertices": [
    {"name": "main", "decl": "#F36", "root": "#F36", "is_root": true},
    {"name": "abs_val", "decl": "#F24", "root": "#F24", "is_root": true}
  ]
}
```

---

## 8. Key pitfalls and precautions ★

### 8.1 SET is not synchronous

**Problem**: Waiting for DATA response after sending SET, never waits (timeout).

**Cause**: SET and EXEC enter the command queue, and only sending POLL will trigger the server processing queue.

**Correct practice**: SET requests must also use POLL loops to wait for results.

```
// ✗ Error
send(SET("plugins.wp.setTimeout", 10))
resp = recv() // always times out

// ✓ Correct
send(SET("plugins.wp.setTimeout", 10))
resp = poll_loop("RQ.1", timeout=30s)
```

### 8.2 Response ID must be verified

**Problem**: After the previous request times out, residual responses will be returned in subsequent requests, causing data confusion.

**Scenario**:
1. Send SET(id=RQ.1) → timeout
2. Send GET(id=RQ.2) → receive DATA(id=RQ.1) (response to the previous request)
3. Mistaking it for the result of GET → The data type is completely wrong

**Correct approach**: Always verify `resp.id == request_id`, and unmatched responses are discarded directly.

### 8.3 Incremental Fetch can only be consumed once

**Issue**: The second call to `fetchX` returns empty data.

**Cause**: Incremental fetch is stateful and only returns each record once.

**Correct approach**: When you need to re-acquire, first call `reloadX` to reset the cursor.

### 8.4 `param_opt` parameter must be omitted and null cannot be passed

**Problem**: `getValues` passes `{"target": "#s2", "callstack": null}` → "Expected int, got null".

**Cause**: Frama-C's optional parameters (`param_opt`) require **not to appear in the JSON object at all**. Passing `null` will be interpreted as a value.

**Correct approach**:
```json
// ✗ Error
{"target": "#s2", "callstack": null}

// ✓ Correct (omit callstack field)
{"target": "#s2"}
```

### 8.5 `printDeclaration` parameter is a pure string

**Question**: Passing `{"marker": "#F24"}` → type error.

**Correct approach**: Directly pass the marker string as `data`.

```json
// ✗ Error
{"cmd":"GET", "request":"kernel.ast.printDeclaration", "data":{"marker":"#F24"}}

// ✓ Correct
{"cmd":"GET", "request":"kernel.ast.printDeclaration", "data":"#F24"}
```

### 8.6 WP `startProofs` requires PVDecl marker

**Question**: Passing `#F24`(AST.Decl) → "invalid marker".

**Cause**: `startProofs` only accepts AST.Marker types. `#F` is AST.Decl, not AST.Marker.

**Correct approach**:
1. First call `printDeclaration("#F24")` to register the marker of the function
2. Convert `#F24` to `#v24` (replace prefix, same number)
3. Pass `#v24` to `startProofs`

```
GET("kernel.ast.printDeclaration", "#F24") // Step 1: Register marker
EXEC("plugins.wp.startProofs", "#v24") // Step 2-3: Use PVDecl marker
```

### 8.7 Frama-C Server does not actively push

Frama-C Server will not actively push any messages (including CMDLINEON/CMDLINEOFF) before the client sends the command for the first time. After connecting, the client must actively send a request to trigger the server's response flow.

---

## 9. Reference implementation pattern

### 9.1 Client architecture

```
FramaCClient
├── transport: Unix Socket connection (read/write)
├── codec: S/L frame codec
├── counter: u64 (generate incremental request ID)
├── get(request, data) → send GET + wait_for_id()
├── set(request, data) → send SET + poll_loop()
├── exec(request, data, timeout) → send EXEC + poll_loop()
├── fetch_all(request) → loop GET until pending==0
└── shutdown() → send SHUTDOWN
```

### 9.2 Recommended POLL parameters

| Parameters | Recommended values ​​| Description |
|------|-------|------|
| POLL interval | 100ms | Ivette uses 50ms, MCP scene 100ms is enough |
| Single recv timeout | 500ms | No response is considered "queue empty" |
| GET total timeout | 10s | GET is synchronous and usually fast |
| SET total timeout | 30s | SET queue processing, slightly slower |
| EXEC total timeout | 600s | EVA/WP may run for several minutes |
| Fetch batch | 20000 | Consistent with Ivette |

### 9.3 Marker cache mode

It is recommended to maintain the mapping cache of function name → marker on the client side:

```
When connecting:
  entries = fetch_all("kernel.ast.fetchFunctions")
  for entry in entries:
      cache[entry.name] = {
          marker: entry.key,
          declaration: entry.decl,
          signature: entry.signature,
          file: entry.sloc.file,
          line: entry.sloc.line,
      }

When using:
  info = cache["abs_val"]
  GET("kernel.ast.printDeclaration", info.declaration) // use #F marker
  EXEC("plugins.wp.startProofs", info.declaration.replace("#F", "#v")) // Use #v marker
```

---

## 10. Source code reference

| Documentation | Content |
|------|------|
| `src/plugins/server/server_socket.ml:135-139` | S/L/W frame encoding implementation |
| `src/plugins/server/main.ml:296-297` | GET executed immediately vs SET/EXEC queued |
| `src/plugins/server/main.ml:352-369` | POLL command handling logic |
| `src/plugins/server/states.ml:302` | Fetch capacity analysis |
| `src/plugins/server/request.ml` | Request registration and dispatch |
| `ivette/src/frama-c/states.ts:429-442` | Ivette paging loop (batch=20000) |
| `ivette/src/frama-c/server.ts:826-831` | Ivette request/response association model |
| `src/plugins/wp/wpApi.ml` | WP API registration (startProofs parameter type) |

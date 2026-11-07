# Angelo-xui-plugin-2 node compatibility findings

Read-only investigation of user source, 2026-11-07. New scratch report only; upstream files were not modified and no source tests/builds were run.

## Audited baseline

- Repository: https://github.com/AngeloSakura/Angelo-xui-plugin-2
- `main`: `bb0bf320301fb03d1975ff1489e36f13324f15d7`, 2026-08-28T12:12:23Z.
- GitHub API shows one initial-import commit with no parents. An exact upstream source commit cannot be established from this history.
- `internal/config/version`: `3.7.0`; `go.mod`: module `github.com/mhsanaei/3x-ui/v3`, Go 1.27.0.
- Local source root for all evidence below: `work/plugin-source/AngeloSakura-Angelo-xui-plugin-2-bb0bf32/`.
- This is the v3 node/client API, not the old v2 `inbounds/addClient` API.

## Decision

A small API-compatible node agent can replace the entire panel while running an unchanged official Xray binary. The multiplier belongs solely to the existing master. The agent must supply raw cumulative traffic and enforce the global billed totals pushed by the master without reporting those totals back as locally generated traffic.

The existing README explicitly supports unmodified official subnodes (lines 27-31); code confirms the same behavior. Required compatibility is behavioral, not just matching endpoint names.

## HTTP contract

- Configured base path followed by `panel/api/...` (normalise the base path to end in `/`).
- `Authorization: Bearer <opaque-token>`; no session cookie or CSRF token needed. Token should be a generated random secret, never a fixed default.
- Success: HTTP 200, JSON `{"success":true,"msg":"","obj":...}`. Failure: `success:false` envelope with a diagnostic, or suitable non-200 status. Remote treats every non-200 as failure.
- Form requests: `application/x-www-form-urlencoded`. Structured client/global requests: `application/json`.
- Every nonempty request body carries `X-Config-Sha256`: lowercase hex SHA-256 of the uncompressed exact request body. Verifying is inexpensive.
- To avoid zstd memory/dependency costs, do NOT advertise `X-3x-Node-Caps: zstd`. Then this master always sends uncompressed bodies, including large configs. Reject unsupported Content-Encoding. Master compression is capability negotiated and only used on bodies >=1024 bytes.
- Remote RPC timeout is 10s; snapshot/global push contexts can shorten it to 4s. Reads must remain responsive during Xray configuration application.
- Source: `internal/web/runtime/remote.go:178`, `internal/util/wirecodec/wirecodec.go`, `internal/web/job/node_traffic_sync_job.go:18`.

## Required endpoints

All paths below are relative to `panel/api/`.

| Method/path | Request | Response `obj` / semantics |
| --- | --- | --- |
| GET `server/status` | none | Object with `cpu` number; `mem:{current,total}` bytes; `xray:{version,state,errorMsg}`; `panelVersion` string; stable persisted `panelGuid` string; `uptime` seconds; `netIO:{up,down}` raw bytes. Probe requires non-null obj and success. |
| GET `inbounds/list` | none | Array of every saved inbound, including disabled inbounds and disabled clients, with raw cumulative inbound up/down and per-client raw clientStats. Stable numeric local IDs and tags. |
| POST `inbounds/add` | Form fields listed below | Created inbound object, at least `{id,tag}` so master can cache local ID. |
| POST `inbounds/update/:id` | Same form | Update saved inbound and Xray; preserve counters. The ID is normally node-local, resolved by tag. |
| POST `inbounds/del/:id` | none | Remove this inbound. Detach its clients but preserve shared client counters/records for other attachments. |
| POST `inbounds/:id/subSortIndex` | Form `subSortIndex` | Subscription metadata update. No reason to restart Xray. |
| POST `clients/add` | JSON `{"client":<Client>,"inboundIds":[localID]}` | Create or attach client; do not clear existing raw traffic. |
| POST `clients/update/:oldEmail?inboundIds=1` | JSON `<Client>` | Update client; the query scopes attachment-specific fields. Rename must move counter/overlay identity rather than silently discard it. |
| POST `clients/:email/detach` | JSON `{"inboundIds":[localID]}` | Detach only selected inbounds, retaining shared record/counters. |
| POST `clients/del/:email` | none | Full client delete: all attachments, counters, master overlays. Master tolerates success=false with `not found` in msg for repeated deletion. |
| POST `clients/resetTraffic/:email` | none | Zero this client's raw counters, clear every master's overlay for it, set client enabled; expired clients can subsequently be disabled by normal expiry enforcement. |
| POST `inbounds/:id/resetTraffic` | none | Zero ONLY this inbound's raw up/down. Does NOT zero clients. See master ID bug below. |
| POST `inbounds/resetAllTraffics` | none | Zero ONLY all inbounds' up/down, update lastTrafficResetTime. Does NOT zero clients or overlays. |
| POST `inbounds/pushClientTraffics` | JSON `{"masterGuid":"...","traffics":[<ClientTraffic>]}` | Store master billed usage separately for quota enforcement; overwrite rows, never accumulate or max-merge them. |
| POST `server/restartXrayService` | none | Restart original Xray; preserve cumulative counters. |
| POST `clients/onlinesByGuid` | none | `{"<stable-panelGuid>":["email",...]}`; prefer actual recent activity. |
| POST `clients/onlines` | none | `["email",...]` fallback. |
| POST `clients/lastOnline` | none | `{"email":unixMilliseconds,...}`. |
| POST `clients/activeInbounds` | none | `{"<stable-panelGuid>":["inbound-tag",...]}`. |
| GET `server/descendants` | none | `[]` for a leaf agent. |
| GET `hosts/list` | none | `[]` if agent has no managed host overrides; master fetches this when adopting new inbounds. |
| GET `server/getWebCertFiles` | none | `{"webCertFile":"...","webKeyFile":"..."}` for available agent web TLS paths, or empty strings if absent. |
| GET `server/clientIps` | none | List `[{"clientEmail":"...","ips":[...]}]`, or `[]` if unavailable. |
| POST `server/clientIps` | same list | Master aggregated IP view; if IP limit not supported, do not pretend it is enforced. |
| POST `clients/clientIpsByGuid` | none | GUID -> email -> array of ClientIpEntry; `{}` if unavailable. |

The master can also call `POST server/updatePanel`; a lightweight agent must return an explicit unsupported result or implement its own safe updater. It must not run the upstream full-panel updater and reinstall the heavy panel.

Source: `internal/web/runtime/remote.go:412-934`; probe schema `internal/web/service/node.go:1238-1340`.

## Inbound payload

The master sends these form fields: `total`, `remark`, `subSortIndex`, `enable`, `expiryTime`, `listen`, `port`, `protocol`, `settings`, `streamSettings`, `tag`, `sniffing`, `shareAddrStrategy`, `shareAddr`, `disableFlow`; `trafficReset` when nonempty; `trafficResetDay` when >0.

The three JSON config fields are serialized JSON text inside form fields. In GET responses the modern v3 format is actual nested JSON objects; the audited master accepts either objects or legacy encoded strings. Fields should survive storage faithfully. Node-local IDs are not master IDs. Master may use an `n<nodeID>-` tag prefix centrally and strips it before pushing.

Counters and quota limits use integer BYTES. Dates (`expiryTime`, `lastOnline`, `lastTrafficResetTime`) use Unix MILLISECONDS. Client `totalGB` is misleadingly named: code copies it directly into ClientTraffic.total, so it also contains BYTES, not GiB. Zero total is unlimited. Zero expiry is no deadline; negative expiry is a duration to activate on first use.

Example returned inbound (abbreviated but correct shapes):

```json
{
  "id":1,"up":100,"down":200,"total":0,"remark":"NAT","enable":true,
  "subSortIndex":1,"expiryTime":0,"trafficReset":"never","trafficResetDay":1,
  "lastTrafficResetTime":0,"listen":"0.0.0.0","port":10001,"protocol":"vless",
  "tag":"in-10001","settings":{"clients":[{"id":"11111111-1111-4111-8111-111111111111","email":"alice","enable":true,"totalGB":10737418240,"expiryTime":0}],"decryption":"none"},
  "streamSettings":{"network":"tcp","security":"none"},"sniffing":{"enabled":false},
  "shareAddrStrategy":"node","shareAddr":"","disableFlow":false,
  "clientStats":[{"id":1,"inboundId":1,"email":"alice","enable":true,"up":100,"down":200,"total":10737418240,"expiryTime":0,"reset":0,"resetDay":0,"resetMax":0,"resetCount":0,"lastOnline":0}]
}
```

Source: `internal/web/runtime/remote.go:796`; `internal/database/model/model.go:47,180,878`; `internal/xray/client_traffic.go`; `internal/web/service/inbound_traffic.go:550-578`.

## Multiplier, duplicate handling, and persistence

1. Xray's per-user stats are keyed by email across inbounds. Maintain one raw cumulative counter per email on the node. If a client is attached to two inbounds, return the SAME node-wide raw clientStats.up/down in both inbound records; do not divide it per inbound.
2. Master folds repeated emails to max(up) and max(down), then compares to one `(nodeID,email)` raw baseline. Baseline advances in the same serialized merge. This deduplicates repeated stats and duplicate polling.
3. Master bills `round(max(0,currentRaw - previousRaw) * trafficMultiplier)` separately per direction, saturating the traffic maximum. Existing node baselines remain RAW. Changing multiplier affects future merges only.
4. New inbound adoption can seed existing raw usage multiplied by the current factor. Ordinary first baseline on an existing known client usually seeds without retroactive charge. Do not manipulate this with invented zero snapshots.
5. Node process/Xray restart must NOT zero persisted raw totals. Otherwise master sees a counter dip, clamps it, and some traffic can be lost. Flush before planned restart; persist Xray per-process baselines/cumulative totals consistently to avoid adding the same Xray count again when only the agent restarts.
6. Actual resets may lower raw totals; master advances its raw baseline, with lifecycle safeguards on dirty/just-pushed snapshots. Never reset raw totals for routine configuration/client edits.
7. Inbound diagnostic up/down and node speed remain raw; only client billing is multiplied.

Source: `internal/web/service/inbound_node.go:267,445,540-561,887-944,1062`; tests `internal/web/service/node_traffic_multiplier_test.go`.

## Master-pushed billing and quota enforcement

Example incoming master push at 3x for the above 100/200 raw counter:

```json
{"masterGuid":"master-guid","traffics":[{"email":"alice","up":300,"down":600,"total":10737418240,"enable":true,"expiryTime":0}]}
```

- Key storage by `(masterGuid,email)`. Only known local clients are accepted; duplicate entries within one push use the last entry. Empty masterGuid is ignored by upstream.
- Store only up/down and local received-at milliseconds for quota purposes. The push does not overwrite client enable/total/expiry or raw counters.
- OVERWRITE per-master values even if lower. This carries master resets. Do not sum successive pushes, do not keep a high-water mark, and do not sum different masters.
- Client must disable if `rawUp+rawDown >= configuredClientTotal`, OR **any single fresh master's** `globalUp+globalDown >= configuredClientTotal`, OR a positive expiry has passed. `total>0` guards quota checks. Fresh means received within 24 hours.
- Enforcement is NOT sum(local,global), NOT sum(masters), and NOT max(up across masters)+max(down across masters). The upstream display overlay uses per-direction maxima; its SQL enforcement uses separate per-master sums.
- Client reset/delete clears all master rows for that email. A normal fresh push can restore authoritative master numbers. Reset endpoints should synchronize with polling/pushing so a pre-reset snapshot is not accidentally restored locally.
- Once disabled, keep client metadata and report enable=false; remove it from generated Xray config or use API removal. Do not delete its saved record/counters merely to enforce quota. A later master enable/reset must work.
- `GET inbounds/list` MUST return raw counters with no global overlay, or the next master poll multiplies its own pushed traffic again and creates a feedback loop.
- Master polls node traffic about every 5s and sends globals about every 30s. It normally detects billed quota exhaustion and pushes a disabled client configuration sooner; global push is backup enforcement.

Source: `internal/web/service/inbound_traffic_global.go:16-24,61-83,102-150,192`; `internal/web/service/inbound_disable.go:35-82`; `internal/web/job/node_traffic_sync_job.go:18-28,296-350`; `internal/web/web.go:293-298`.

## Inbound limits and reset distinctions

- Node itself must enforce inbound `total` and positive `expiryTime`, using raw inbound counters. Master `disableInvalidInbounds` only applies to `node_id IS NULL`, so it does not directly enforce a remote inbound's own limit.
- Client quota enforcement is separate from inbound quota. Keep disabled inbounds in API results; omit them only from actual Xray runtime config.
- `clients/resetTraffic/:email`: zero client usage, clear its globals, re-enable client, preserve unrelated inbound/client totals.
- `inbounds/:id/resetTraffic`: zero only specified inbound usage.
- `inbounds/resetAllTraffics`: zero only all inbound usage; do not clear client usage/global rows.
- Upstream also has `clients/resetAllTraffics` for all client counters, but Remote does not call it for its inbound reset-all operation. Do not conflate these APIs.

Source: `internal/web/service/inbound_disable.go:15-31`; `internal/web/service/inbound_traffic.go:619-830`; `internal/web/service/client_traffic.go:17-63,200-225`.

## Existing master limitations needing documentation or a small separate patch

1. `Remote.ResetInboundTraffic` (`internal/web/runtime/remote.go:697`) sends the **master-local** `ib.Id`, unlike update/delete which resolve node-local ID by tag. `InboundService.ResetInboundTraffic` passes the master record (`inbound_traffic.go:809-830`). If master and node IDs differ, reset may fail or target another inbound. A node cannot infer the intended tag from this request. Correct master fix is resolveRemoteID(ctx,ib.Tag) first, then format path with resolved ID. Never guess IDs in the agent.
2. Master `node-sync` allowlist omits `clients/activeInbounds` and `inbounds/:id/subSortIndex` even though Remote uses them. Agent's own token route allowlist can include them; this is not an obstacle when replacing the remote server.
3. No native API field tells a node its multiplier. A disconnected node cannot exactly extrapolate multiplied billing after its last global push. Preserve the documented master-controlled model; do not claim real-time billed enforcement during indefinite disconnection.
4. `limitIp`, IP histories, advanced renewal schedules, and Xray-external protocols (AmneziaWG/MTProto) must be either actually implemented or explicitly rejected/documented. Empty IP endpoint responses should not imply IP enforcement works.

## Verification priorities for the new agent

- Exact recorded v3 request bodies and forms accepted, raw object response decoding accepted by the existing master.
- Two inbounds sharing one email do not double bill; changing 3x to 2x preserves the raw baseline.
- Repeated global pushes do not change raw GET counters; lower pushes replace previous numbers; two masters do not add; reset removes all overlays.
- Counter persistence across agent restart while Xray survives, and Xray restart while agent survives; no duplicated accounting.
- Config/client edits keep accumulated traffic, disabled clients, unknown supported Xray settings, and shared attachments intact.
- Inbound reset is separate from client reset. Client and inbound byte limits/expiry actually stop runtime traffic.
- Real low-memory Linux RSS and peak measurements include BOTH agent and official Xray; 64 MiB feasibility must not be claimed from a Windows compile or only agent RSS.

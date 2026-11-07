# Scope and acceptance

The user requires a tiny NAT VPS node for 64/128 MiB machines, with an unchanged official Xray binary, no local web panel, and API-token control from their existing Angelo-xui-plugin-2 master. The master applies traffic multipliers. Master and node upgrades must be independent and preserve users, tokens, configuration and cumulative traffic. Code review and meaningful validation are required before publishing release assets.

Protocol baseline: AngeloSakura/Angelo-xui-plugin-2 commit bb0bf320301fb03d1975ff1489e36f13324f15d7, v3.7.0. Full report in docs/PROTOCOL.md. Support VLESS, VMess, Trojan and Shadowsocks with original Xray JSON transports; reject unsupported sidecars and IP limits explicitly. No UI, database, subscription server or Telegram bot in the node. The master retains those jobs.

Required behavior: bearer-authenticated node probe; stable persisted GUID; inbound and client create/update/delete; shared-client identity and raw cumulative counters; separate master usage overlays for quota checks; expiry and quota enforcement; client reset distinct from inbound reset; state survives normal service restart/update; exact Xray configuration validation and rollback on failure; bounded payloads and low-memory defaults. Do not claim 64 MiB guarantees from binary size, Windows measurements, or agent-only RSS.

Release gate: Go tests and vet, actual official Xray traffic/disable/restart integration, Linux 64/128 MiB cgroup measurements including agent+Xray, installation/update preservation checks, and independent standards/spec reviews. Publish only after fixing material findings. Document bounded loss on forced termination and disconnection limits of master-only multiplier accounting.

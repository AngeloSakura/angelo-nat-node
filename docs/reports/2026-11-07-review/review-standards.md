# Independent standards and lifecycle review

> 历史记录（2026-11-07），本次仅归档，未重新执行审查或测试。初始失败、后续修复和当时未验证的边界按原记录保留；发布时结果见[发布验证](../../VALIDATION.md)，实机结论见[全部报告](../README.md)。文中 work/ 路径为原本地工作目录，不是公开可用的部署路径。

Review date: 2026-11-07. Scope: `outputs/angelo-nat-node`. Read-only production review; the reviewer subsequently added only `internal/node/lifecycle_regression_test.go` under the coordinator's assignment. No commits were created.

## Standards sources

No `AGENTS.md`, `CODING_STANDARDS.md`, or `CONTRIBUTING.md` was found in the deliverable or its workspace ancestors. `SPEC.md` and `docs/PROTOCOL.md` document compatibility, lifetime, accounting, and release requirements. Therefore there are no claimed hard coding-style violations; the findings below concern documented behavior and correctness.

## Material findings before fixes

1. **P1: reads wait for Xray replacement.** `internal/node/api.go` held the global mutation mutex across collection, process replacement, disk persistence, and response encoding. Both GET status and inbound-list requests were blocked by a slow Apply, contrary to the master's four-second snapshot deadline described in `docs/PROTOCOL.md`. Reads need a consistent committed snapshot that can be served while the mutation continues.
2. **P1: unbounded readiness wait.** Background reconciliation and crash recovery passed the daemon lifetime context into Apply; save rollback passed `context.Background()`. The readiness loop in `internal/node/process.go` can wait indefinitely if Xray remains alive without a working stats endpoint. Every replacement and rollback requires its own finite deadline.
3. **P1: traffic loss following failed replacement and successful rollback.** Reconciliation and the explicit restart API reset the previous-process baseline only when Apply succeeds. Apply may return an error after restarting the old configuration in a new process. If the old baseline was 1,000 and the replacement process reaches 1,500 before collection, only 500 additional bytes are counted. A process replacement must invalidate its baseline even when the enclosing operation returns an error.

Heuristic, not a hard documented-standard violation: the repeated Apply / clear-baseline / save sequence across commit, reconcile, and explicit restart is duplicated lifecycle logic. Centralizing it is justified by their demonstrably inconsistent failure handling.

## Regression tests

`internal/node/lifecycle_regression_test.go` uses a synchronized fake Runtime to test observable outcomes without depending on platform Xray availability.

- During a paused update Apply, GET `server/status` and `inbounds/list` must finish within 750 ms and the list must expose the committed old inbound. Both successful-commit and failed-update paths are covered.
- Failed restart, update, and reconciliation simulate an old-configuration restart with zeroed process counters. Accumulated user and inbound counters must reach 2,500 after 1,000 old-process bytes and 1,500 new-process bytes. A repeated sample must not count twice.
- Background reconciliation must supply Apply with a positive deadline no longer than 15 seconds; the fake immediately returns, so the test does not wait for the timeout.

## Initial execution

Command: `go test ./internal/node -run '^TestLifecycle' -count=1 -timeout=30s`

Initial result: **FAIL**, as expected before the coordinator's production fixes. The two responsive-read cases failed. Restart and reconcile returned user/inbound totals of 1,500 instead of 2,500. Background reconcile had no deadline. The failed-update baseline case already passed. No production files were edited by this reviewer.

These tests do not establish Linux 64/128 MiB feasibility, real Xray protocol interoperability, or installer/update preservation. Those remain separate release gates.

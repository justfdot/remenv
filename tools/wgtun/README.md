# wgtun

Autonomous RouterOS 7 WireGuard HUB↔site planner and guarded REST executor.
Version 0.2 implements hub-core apply contract 1.1. Requires Rust 1.89+.

## Build and test

```sh
cargo build
cargo test
python3 tests/executor.py
```

The Python suite runs two isolated RouterOS REST fixtures on 127.0.0.1; no real
routers or credentials are used. It requires Python 3. These fixtures test the
protocol and failure handling, not RouterOS syntax or a live tunnel.

`make install-local` explicitly replaces `~/.local/bin/wgtun`. Building alone
does not install or change a router. Before installation, point hub-core's
`WGTUN_BIN` at the candidate binary.

## Profiles and independent access

Read-only commands retain their original profile resolution. Write-capable
commands require passwords in `WGTUN_<PROFILE>_PASSWORD` (not config files).
Public URLs/usernames remain in `~/.wgtun/config.toml` or `WGTUN_*` environment
variables. `WGTUN_CONFIG` overrides the config path. Never put private WireGuard
keys in site.yaml; unknown plan fields are rejected.

```toml
[profiles.hub]
url = "https://10.21.1.1"
username = "automation"
management_interface = "ether-mgmt"
independent_path_verified = true

[profiles.acme-01]
url = "https://10.22.1.1"
username = "automation"
management_interface = "ether-mgmt"
independent_path_verified = true
```

`independent_path_verified` is an **operator attestation**, not automatic route
proof: set it only after a fresh independent management reconnect, with forward
and return paths checked to avoid the tunnel being changed. The executor also
reads the target's addresses: v1 requires a literal IPv4 REST URL hosted on the
named management interface, distinct from the tunnel interface. DNS names,
NAT/port-forward endpoints and unproved paths fail closed for REST apply. They
remain usable for read-only discovery and manual Safe Mode imports.

No redirects or HTTP proxies are used by the executor. Only enabled existing
WireGuard interfaces with the expected **local** public key pass preconditions.
URLs containing credentials, paths, query strings or fragments are rejected.
Use HTTPS and a trusted certificate; insecure TLS remains an explicit profile
choice. Profiles must point at distinct devices.

## Commands

```sh
wgtun --json doctor
wgtun --json profiles list
wgtun --json nodes list --profile hub
wgtun --json request get --profile hub /rest/interface/wireguard
wgtun --json plan validate --file site.yaml
wgtun --json plan render --file site.yaml --out generated
wgtun --json preview --file site.yaml --out generated/plan.json
# Review preview.conflicts, independent_paths, diff, operations and before first.
wgtun --json apply --preview generated/plan.json --confirm <confirm_hash> --operation-id <uuid>
```

`request` remains GET-only. The legacy `plan apply --dry-run` remains read-only;
actual writes are exclusively behind top-level `apply` with a persisted preview.
`.rsc` rendering and REST application share the same typed operation model.
Manual `.rsc` imports still need review, independent access and Safe Mode.

The executor only manages exact `<tag>:address`/`<tag>:peer` objects on the
specified tunnel interface. It does not create/change interfaces, keys, routes,
firewall or NAT. It rejects conflicting unowned objects, changes only differing
fields and removes extra owned records. Public configuration is selected/projected;
private/PSK keys and runtime counters are never persisted in previews or reports.

Confirmations bind canonical JSON of operations, targets and normalized state,
including interface public keys/disabled state and internal object IDs. Targets
include the complete URL (scheme/host/port), profile, username and interface.
State is re-read before writes and before each ensure operation. Drift returns
`state_changed`; conflicts and failed independent access checks refuse execution.

Before the first write, apply persists `<preview>.<operation-id>.before.json`
(mode 0600), fsyncs it and consumes the preview. A consumed preview cannot be
executed again, even after an unchanged or unknown result. Use a fresh preview.
CLI file locks serialize resources by URL in the config directory; hub-core
also provides PostgreSQL locks across processes and persistent operation-id dedup.
Do not delete lock/consumption files to retry an interrupted operation.

Reports distinguish `applied`, `unchanged`, `failed`, `unknown` per device.
`overall=applied` requires successful read-back verification on both devices;
a no-change execution succeeds. A failed/unknown HUB stops before site. A write
transport error is `unknown`, not proof of failure. There is no distributed
transaction and no automatic rollback. Reports include before/expected state per
operation, read-back state/diff, timestamps, operation id and a canonical hash
(excluding the report_hash field itself). A durable report is also written next
to the preview. Hub-core retains reports for HTTP retries.

REST configuration verification does not prove handshake, routing, DNS, Internet
or successful management reconnect. Those require an independently approved
lab/site check before treating a tunnel as operational.

## JSON

With `--json`, stdout is one envelope: `{ "ok": true, "data": ... }` or
`{ "ok": false, "error": { "code", "message" } }`. A completed execution can
return `ok:true` with `overall:partial|failed|unknown`; consumers must inspect the
report. Preflight refusals use stable error codes and perform no device writes.

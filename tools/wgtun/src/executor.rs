//! The only write-capable path: immutable model -> persisted preview -> guarded executor.
use super::*;
use base64::Engine;
use reqwest::{redirect::Policy, Method};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const CONTRACT: &str = "1.1";
const ADDRESS: &str = "/rest/ip/address";
const PEER: &str = "/rest/interface/wireguard/peers";

#[derive(Debug)]
struct Rejection(&'static str);
impl std::fmt::Display for Rejection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for Rejection {}
fn reject<T>(code: &'static str) -> Result<T> {
    Err(Rejection(code).into())
}
pub fn error_code(error: &anyhow::Error) -> &str {
    error
        .downcast_ref::<Rejection>()
        .map(|e| e.0)
        .unwrap_or("wgtun_error")
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Target {
    profile: String,
    url: String,
    username: String,
    interface: String,
    management_interface: String,
    public_key: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Operation {
    CheckInterface {
        device: String,
        interface: String,
        expect_public_key: String,
    },
    EnsureAddress {
        device: String,
        interface: String,
        address: String,
        comment: String,
    },
    EnsurePeer {
        device: String,
        interface: String,
        peer_public_key: String,
        allowed_addresses: Vec<String>,
        comment: String,
        endpoint: Option<String>,
        endpoint_port: u16,
        keepalive_seconds: u16,
    },
}
impl Operation {
    fn device(&self) -> &str {
        match self {
            Self::CheckInterface { device, .. }
            | Self::EnsureAddress { device, .. }
            | Self::EnsurePeer { device, .. } => device,
        }
    }
    fn name(&self) -> &str {
        match self {
            Self::CheckInterface { .. } => "check_interface",
            Self::EnsureAddress { .. } => "ensure_address",
            Self::EnsurePeer { .. } => "ensure_peer",
        }
    }
    fn desired(&self) -> Option<(&'static str, Value)> {
        match self {
            Self::CheckInterface { .. } => None,
            Self::EnsureAddress {
                interface,
                address,
                comment,
                ..
            } => Some((
                ADDRESS,
                json!({"interface":interface,"address":address,"comment":comment,"disabled":"false"}),
            )),
            Self::EnsurePeer {
                interface,
                peer_public_key,
                allowed_addresses,
                comment,
                endpoint,
                endpoint_port,
                keepalive_seconds,
                ..
            } => {
                let mut allowed = allowed_addresses.clone();
                allowed.sort();
                Some((
                    PEER,
                    json!({"interface":interface,"public-key":peer_public_key,"allowed-address":allowed.join(","),"comment":comment,"endpoint-address":endpoint.clone().unwrap_or_default(),"endpoint-port":endpoint_port.to_string(),"persistent-keepalive":keepalive_seconds.to_string(),"disabled":"false"}),
                ))
            }
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Preview {
    contract_version: String,
    tag: String,
    input: Plan,
    targets: BTreeMap<String, Target>,
    operations: Vec<Operation>,
    before: BTreeMap<String, Value>,
    conflicts: Vec<String>,
    diff: BTreeMap<String, Vec<Value>>,
    independent_paths: BTreeMap<String, Value>,
    plan_hash: String,
    state_hash: BTreeMap<String, String>,
    confirm_hash: String,
    created_at: String,
}
struct Connection {
    target: Target,
    client: Client,
    password: String,
}
impl Connection {
    fn open(profile: &str, interface: &str, public_key: &str) -> Result<Self> {
        let (base, username, password, insecure, source) = resolved_profile(profile)?;
        if source != "env" {
            return reject("credentials_not_env");
        }
        let url = url::Url::parse(&base)?;
        if !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || url.path() != "/"
        {
            return reject("invalid_target");
        }
        let config = read_config()?;
        let p = config.profiles.get(profile).cloned().unwrap_or_default();
        // Explicit operator attestation plus read-back of the management IP/interface.
        if !p.independent_path_verified {
            return reject("no_independent_path");
        }
        let management_interface = p
            .management_interface
            .filter(|m| !m.is_empty() && m != interface)
            .ok_or(Rejection("no_independent_path"))?;
        let target = Target {
            profile: profile.into(),
            url: base,
            username,
            interface: interface.into(),
            management_interface,
            public_key: public_key.into(),
        };
        Ok(Self {
            target,
            password,
            client: Client::builder()
                .no_proxy()
                .redirect(Policy::none())
                .timeout(Duration::from_secs(12))
                .danger_accept_invalid_certs(insecure)
                .build()?,
        })
    }
    fn get(&self, path: &str) -> Result<Value> {
        let response = self
            .client
            .get(format!("{}{}", self.target.url, path))
            .basic_auth(&self.target.username, Some(&self.password))
            .send()
            .map_err(|_| anyhow!("RouterOS read transport error"))?;
        if !response.status().is_success() {
            return reject("read_failed");
        }
        response
            .json()
            .map_err(|_| anyhow!("RouterOS read returned invalid JSON"))
    }
    fn write(
        &self,
        method: Method,
        path: &str,
        body: &Value,
    ) -> std::result::Result<(), &'static str> {
        // A transport/5xx error cannot prove that the write did not happen.
        let request = self
            .client
            .request(method, format!("{}{}", self.target.url, path))
            .basic_auth(&self.target.username, Some(&self.password))
            .json(body);
        let response = request.send().map_err(|_| "unknown")?;
        if response.status().is_success() {
            Ok(())
        } else if response.status().is_client_error() {
            Err("failed")
        } else {
            Err("unknown")
        }
    }
}

fn key_valid(key: &str) -> bool {
    base64::engine::general_purpose::STANDARD
        .decode(key)
        .is_ok_and(|v| v.len() == 32 && v.iter().any(|b| *b != 0))
}
pub fn validate(plan: &Plan) -> Result<()> {
    model(plan).map(|_| ())
}

fn model(plan: &Plan) -> Result<Vec<Operation>> {
    validate_plan(plan)?;
    if !key_valid(&plan.hub.public_key)
        || !key_valid(&plan.site.public_key)
        || plan.hub.public_key == plan.site.public_key
    {
        return reject("invalid_public_key");
    }
    if plan.tag.len() <= 6
        || !plan
            .tag
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || ":-_".contains(c))
    {
        return reject("invalid_tag");
    }
    let (endpoint, port) = match plan.site.endpoint.rsplit_once(':') {
        Some((host, port)) if !host.is_empty() && !host.contains(':') => {
            (host.to_owned(), port.parse::<u16>()?)
        }
        _ => return reject("invalid_endpoint"),
    };
    if port == 0 || plan.hub.listen_port == 0 {
        return reject("invalid_endpoint");
    }
    let mut ops = Vec::new();
    for (side, iface, public, address, peer, allowed, ep, ep_port, keepalive) in [
        (
            "hub",
            &plan.hub.interface,
            &plan.hub.public_key,
            &plan.hub.address,
            &plan.site.public_key,
            [
                vec![host_cidr(&plan.site.address)?],
                plan.site.lan_networks.clone(),
            ]
            .concat(),
            None,
            13231,
            0,
        ),
        (
            "site",
            &plan.site.interface,
            &plan.site.public_key,
            &plan.site.address,
            &plan.hub.public_key,
            [
                vec![host_cidr(&plan.hub.address)?],
                plan.site.allowed_addresses.clone(),
            ]
            .concat(),
            Some(endpoint),
            port,
            plan.site.keepalive_seconds,
        ),
    ] {
        if !iface
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
        {
            return reject("invalid_interface");
        }
        ops.push(Operation::CheckInterface {
            device: side.into(),
            interface: iface.clone(),
            expect_public_key: public.clone(),
        });
        ops.push(Operation::EnsureAddress {
            device: side.into(),
            interface: iface.clone(),
            address: address.clone(),
            comment: format!("{}:address", plan.tag),
        });
        ops.push(Operation::EnsurePeer {
            device: side.into(),
            interface: iface.clone(),
            peer_public_key: peer.clone(),
            allowed_addresses: allowed,
            comment: format!("{}:peer", plan.tag),
            endpoint: ep,
            endpoint_port: ep_port,
            keepalive_seconds: keepalive,
        });
    }
    Ok(ops)
}
fn connections(plan: &Plan) -> Result<BTreeMap<String, Connection>> {
    let hub = Connection::open(&plan.hub.profile, &plan.hub.interface, &plan.hub.public_key)?;
    let site = Connection::open(
        &plan.site.profile,
        &plan.site.interface,
        &plan.site.public_key,
    )?;
    if hub.target.url == site.target.url {
        return reject("same_target");
    }
    Ok(BTreeMap::from([("hub".into(), hub), ("site".into(), site)]))
}
pub fn hash(value: &Value) -> String {
    // serde_json maps are BTreeMaps (no preserve_order feature), recursively sorted.
    format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).expect("JSON serialization"))
    )
}
fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
fn truth(v: &Value, key: &str) -> bool {
    v[key] == true || v[key] == "true" || v[key] == "yes"
}
fn items(v: &Value) -> Result<&Vec<Value>> {
    v.as_array()
        .ok_or_else(|| anyhow!("RouterOS list is not an array"))
}
fn project(v: &Value, path: &str) -> Value {
    let keys = if path == ADDRESS {
        vec!["interface", "address", "comment", "disabled"]
    } else {
        vec![
            "interface",
            "public-key",
            "allowed-address",
            "comment",
            "endpoint-address",
            "endpoint-port",
            "persistent-keepalive",
            "disabled",
        ]
    };
    let mut out = serde_json::Map::new();
    for key in keys {
        let value = match key {
            "disabled" => truth(v, key).to_string(),
            "allowed-address" => {
                let mut a: Vec<_> = text(v, key)
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .collect();
                a.sort();
                a.join(",")
            }
            "persistent-keepalive" => {
                let t = text(v, key);
                let seconds = if let Some(s) = t.strip_suffix('s') {
                    s.to_owned()
                } else if t.contains(':') {
                    let parts: Vec<u64> = t.split(':').filter_map(|x| x.parse().ok()).collect();
                    if parts.len() == 3 {
                        (parts[0] * 3600 + parts[1] * 60 + parts[2]).to_string()
                    } else {
                        t.into()
                    }
                } else {
                    t.into()
                };
                if seconds.is_empty() {
                    "0".into()
                } else {
                    seconds
                }
            }
            "endpoint-port" => {
                if text(v, key).is_empty() {
                    "13231".into()
                } else {
                    text(v, key).into()
                }
            }
            _ => text(v, key).to_owned(),
        };
        out.insert(key.into(), Value::String(value));
    }
    Value::Object(out)
}
struct Snapshot {
    state: Value,
    conflicts: Vec<String>,
    independent: Value,
}
fn snapshot(conn: &Connection, tag: &str, ops: &[Operation]) -> Result<Snapshot> {
    // Request only public configuration: RouterOS may otherwise return private/PSK keys.
    let interfaces = conn.get("/rest/interface/wireguard?.proplist=name,public-key,disabled")?;
    let addresses = conn
        .get("/rest/ip/address?.proplist=.id,interface,address,comment,disabled,dynamic,invalid")?;
    let peers=conn.get("/rest/interface/wireguard/peers?.proplist=.id,interface,public-key,allowed-address,comment,endpoint-address,endpoint-port,persistent-keepalive,disabled")?;
    let mut conflicts = Vec::new();
    let iface: Vec<_> = items(&interfaces)?
        .iter()
        .filter(|v| text(v, "name") == conn.target.interface)
        .collect();
    if iface.len() != 1
        || text(iface[0], "public-key") != conn.target.public_key
        || truth(iface[0], "disabled")
    {
        conflicts.push("interface_precondition".into());
    }
    let host = url::Url::parse(&conn.target.url)?
        .host_str()
        .unwrap_or_default()
        .to_owned();
    let independent = host.parse::<Ipv4Addr>().is_ok()
        && items(&addresses)?.iter().any(|v| {
            text(v, "interface") == conn.target.management_interface
                && text(v, "address").split('/').next() == Some(host.as_str())
                && !truth(v, "disabled")
                && !truth(v, "invalid")
        });
    let mut owned = BTreeMap::new();
    for (path, rows, suffix) in [(ADDRESS, &addresses, "address"), (PEER, &peers, "peer")] {
        let comment = format!("{tag}:{suffix}");
        let mut objects = Vec::new();
        for row in items(rows)? {
            let tagged = text(row, "comment") == comment;
            if tagged && text(row, "interface") != conn.target.interface {
                conflicts.push("ownership_on_other_interface".into());
            }
            if tagged && text(row, "interface") == conn.target.interface {
                if truth(row, "dynamic") || truth(row, "invalid") {
                    conflicts.push("non_static_object".into());
                }
                let id = text(row, ".id");
                if !id.starts_with('*')
                    || !id[1..].chars().all(|c| c.is_ascii_hexdigit())
                    || id.len() < 2
                {
                    return reject("invalid_object_id");
                }
                objects.push(json!({"id":id,"config":project(row,path)}));
            } else {
                for op in ops {
                    if let Some((op_path, want)) = op.desired() {
                        let collision = if path == ADDRESS {
                            text(row, "address").split('/').next()
                                == text(&want, "address").split('/').next()
                        } else {
                            text(row, "public-key") == text(&want, "public-key")
                                || (text(row, "interface") == conn.target.interface
                                    && text(row, "allowed-address").split(',').any(|a| {
                                        text(&want, "allowed-address").split(',').any(|b| {
                                            networks_overlap(a.trim(), b.trim()).unwrap_or(true)
                                        })
                                    }))
                        };
                        if op_path == path && collision {
                            conflicts.push("unowned_collision".into());
                        }
                    }
                }
            }
        }
        objects.sort_by_key(|v| v.to_string());
        owned.insert(suffix, json!(objects));
    }
    Ok(Snapshot {
        state: json!({"interface":iface.first().map(|v|json!({"name":v["name"],"public-key":v["public-key"],"disabled":truth(v,"disabled")})),"address":owned["address"],"peer":owned["peer"]}),
        conflicts,
        independent: json!({"verified":independent,"management_interface":conn.target.management_interface,"operator_attested":true}),
    })
}
fn build_preview(plan: Plan) -> Result<(Preview, BTreeMap<String, Connection>)> {
    let ops = model(&plan)?;
    let conns = connections(&plan)?;
    let mut before = BTreeMap::new();
    let mut hashes = BTreeMap::new();
    let mut paths = BTreeMap::new();
    let mut conflicts = Vec::new();
    for side in ["hub", "site"] {
        let side_ops: Vec<_> = ops
            .iter()
            .filter(|op| op.device() == side)
            .cloned()
            .collect();
        let snap = snapshot(&conns[side], &plan.tag, &side_ops)?;
        hashes.insert(side.into(), hash(&snap.state));
        before.insert(side.into(), snap.state);
        paths.insert(side.into(), snap.independent);
        conflicts.extend(snap.conflicts.into_iter().map(|c| format!("{side}:{c}")));
    }
    let targets = conns
        .iter()
        .map(|(k, c)| (k.clone(), c.target.clone()))
        .collect::<BTreeMap<_, _>>();
    let plan_hash = hash(&json!({"contract_version":CONTRACT,"plan":ops,"targets":targets}));
    let confirm_hash = hash(&json!({"plan_hash":plan_hash,"state":hashes}));
    let diff = ["hub", "site"]
        .into_iter()
        .map(|side| {
            let side_ops: Vec<_> = ops
                .iter()
                .filter(|op| op.device() == side)
                .cloned()
                .collect();
            (side.to_owned(), verify(&before[side], &side_ops))
        })
        .collect();
    Ok((
        Preview {
            contract_version: CONTRACT.into(),
            tag: plan.tag.clone(),
            input: plan,
            targets,
            operations: ops,
            before,
            conflicts,
            diff,
            independent_paths: paths,
            plan_hash,
            state_hash: hashes,
            confirm_hash,
            created_at: now(),
        },
        conns,
    ))
}
fn persist_new(path: &Path, value: &Value) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(&serde_json::to_vec_pretty(value)?)?;
    file.sync_all()?;
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::File::open(parent)?.sync_all()?;
    }
    Ok(())
}
pub fn preview_file(file: &Path, out: &Path) -> Result<Value> {
    let (preview, _) = build_preview(read_plan(file)?)?;
    let value = serde_json::to_value(preview)?;
    persist_new(out, &value)?;
    Ok(value)
}
fn verify(state: &Value, ops: &[Operation]) -> Vec<Value> {
    let mut diff = Vec::new();
    for op in ops {
        if let Some((path, want)) = op.desired() {
            let key = if path == ADDRESS { "address" } else { "peer" };
            let rows = state[key].as_array().unwrap();
            if rows.len() != 1 || rows[0]["config"] != want {
                diff.push(json!({"op":op.name(),"expected":want,"actual":rows}));
            }
        }
    }
    diff
}
fn device_apply(conn: &Connection, tag: &str, before: &Value, ops: &[Operation]) -> Value {
    let mut results = Vec::new();
    let mut changed = false;
    for op in ops {
        let Some((path, want)) = op.desired() else {
            results.push(json!({"op":op.name(),"outcome":"ok"}));
            continue;
        };
        let key = if path == ADDRESS { "address" } else { "peer" };
        let rows = before[key].as_array().unwrap();
        match snapshot(conn, tag, ops) {
            Ok(current)
                if current.state[key] == before[key]
                    && current.state["interface"] == before["interface"]
                    && current.conflicts.is_empty()
                    && current.independent["verified"] == true => {}
            _ => {
                let result = if changed { "unknown" } else { "failed" };
                results
                    .push(json!({"op":op.name(),"outcome":result,"reason":"precondition_changed"}));
                return json!({"profile":conn.target.profile,"result":result,"changed":changed,"operations":results,"verification":{"ok":false,"diff":[],"reason":"precondition_changed"}});
            }
        }
        let mut actions = Vec::new();
        let identity = if path == ADDRESS {
            "address"
        } else {
            "public-key"
        };
        let first = rows
            .iter()
            .find(|v| v["config"] == want)
            .or_else(|| {
                rows.iter()
                    .find(|v| v["config"][identity] == want[identity])
            })
            .or_else(|| rows.first());
        if let Some(first) = first {
            // Keep the already-correct identity; delete extras before update to avoid
            // RouterOS duplicate-public-key/address conflicts inside our own tag.
            for extra in rows.iter().filter(|v| v["id"] != first["id"]) {
                actions.push((
                    Method::DELETE,
                    format!("{path}/{}", text(extra, "id")),
                    json!({}),
                    "deleted",
                ));
            }
            if first["config"] != want {
                actions.push((
                    Method::PATCH,
                    format!("{path}/{}", text(first, "id")),
                    want.clone(),
                    "updated",
                ));
            }
        } else {
            actions.push((Method::PUT, path.into(), want.clone(), "created"));
        }
        let mut outcome = "unchanged";
        for (method, url, body, action) in actions {
            match conn.write(method, &url, &body) {
                Ok(()) => {
                    changed = true;
                    outcome = if action == "deleted" {
                        "updated"
                    } else {
                        action
                    };
                }
                Err(result) => {
                    results.push(
                        json!({"op":op.name(),"outcome":result,"before":rows,"expected":want}),
                    );
                    return json!({"profile":conn.target.profile,"result":result,"changed":changed,"operations":results,"verification":{"ok":false,"diff":[],"reason":"write_did_not_complete"}});
                }
            }
        }
        results.push(json!({"op":op.name(),"outcome":outcome,"before":rows,"expected":want}));
    }
    match snapshot(conn, tag, ops) {
        Ok(after) => {
            let mut diff = verify(&after.state, ops);
            for conflict in after.conflicts {
                diff.push(json!({"conflict":conflict}));
            }
            if after.independent["verified"] != true {
                diff.push(json!({"conflict":"no_independent_path"}));
            }
            json!({"profile":conn.target.profile,"result":if diff.is_empty(){if changed{"applied"}else{"unchanged"}}else{"failed"},"changed":changed,"operations":results,"verification":{"ok":diff.is_empty(),"diff":diff},"after":after.state})
        }
        Err(_) => {
            json!({"profile":conn.target.profile,"result":"unknown","changed":changed,"operations":results,"verification":{"ok":false,"diff":[],"reason":"read_failed"}})
        }
    }
}
fn resource_locks(targets: &BTreeMap<String, Connection>) -> Result<Vec<fs::File>> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let directory = config_path()
        .parent()
        .ok_or_else(|| anyhow!("invalid config path"))?
        .join("apply-locks");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&directory)?;
    let keys: std::collections::BTreeSet<_> = targets
        .values()
        .map(|c| hash(&json!(c.target.url)))
        .collect();
    let mut locks = Vec::new();
    for key in keys {
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(directory.join(key))?;
        if file.try_lock().is_err() {
            return reject("resource_busy");
        }
        locks.push(file);
    }
    Ok(locks)
}

pub fn apply_file(path: &Path, confirm: &str, operation_id: &str) -> Result<Value> {
    if operation_id.len() != 36
        || operation_id.chars().enumerate().any(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c != '-'
            } else {
                !c.is_ascii_hexdigit()
            }
        })
    {
        return reject("invalid_operation_id");
    }
    let old: Preview = serde_json::from_slice(&fs::read(path)?)?;
    if old.contract_version != CONTRACT {
        return reject("contract_version");
    }
    let started = now();
    let _locks = resource_locks(&connections(&old.input)?)?;
    let (fresh, conns) = build_preview(old.input)?;
    if fresh.targets != old.targets
        || fresh.operations != old.operations
        || fresh.before != old.before
        || fresh.plan_hash != old.plan_hash
        || fresh.state_hash != old.state_hash
        || fresh.confirm_hash != old.confirm_hash
        || confirm != fresh.confirm_hash
    {
        return reject("state_changed");
    }
    if !fresh.conflicts.is_empty() {
        return reject("conflict");
    }
    if fresh
        .independent_paths
        .values()
        .any(|v| v["verified"] != true)
    {
        return reject("no_independent_path");
    }
    // Persist authoritative recovery state before the first write. Operation ids are single-use
    // locally; a crash leaves the marker in place and forces inspection/new preview.
    // Consume even an unchanged/unknown preview: all later executions require a fresh read.
    if path.with_extension("consumed").exists() {
        return reject("preview_consumed");
    }
    persist_new(
        &path.with_extension("consumed"),
        &json!({"operation_id":operation_id}),
    )?;
    let journal = path.with_extension(format!("{operation_id}.before.json"));
    persist_new(&journal, &serde_json::to_value(&fresh)?)?;
    let mut devices = BTreeMap::new();
    for side in ["hub", "site"] {
        // Recheck immediately before each side, too: hub writes may affect site reachability.
        let ops: Vec<_> = fresh
            .operations
            .iter()
            .filter(|op| op.device() == side)
            .cloned()
            .collect();
        let result = match snapshot(&conns[side], &fresh.tag, &ops) {
            Ok(snap)
                if snap.state == fresh.before[side]
                    && snap.conflicts.is_empty()
                    && snap.independent["verified"] == true =>
            {
                device_apply(&conns[side], &fresh.tag, &snap.state, &ops)
            }
            _ => {
                json!({"profile":conns[side].target.profile,"result":"failed","operations":[],"verification":{"ok":false,"diff":[],"reason":"precondition_changed"}})
            }
        };
        let success = result["verification"]["ok"] == true;
        devices.insert(side, result);
        if !success {
            break;
        }
    }
    for side in ["hub", "site"] {
        devices.entry(side).or_insert_with(||json!({"profile":conns[side].target.profile,"result":"failed","operations":[],"verification":{"ok":false,"diff":[],"reason":"not_started"}}));
    }
    let good = devices
        .values()
        .filter(|v| v["verification"]["ok"] == true)
        .count();
    let unknown = devices.values().any(|v| v["result"] == "unknown");
    let overall = if good == 2 {
        "applied"
    } else if good > 0 {
        "partial"
    } else if unknown {
        "unknown"
    } else {
        "failed"
    };
    let mut report = json!({"contract_version":CONTRACT,"tag":fresh.tag,"operation_id":operation_id,"confirm_hash":confirm,"overall":overall,"devices":devices,"started_at":started,"finished_at":now()});
    report["report_hash"] = json!(hash(&report));
    persist_new(
        &path.with_extension(format!("{operation_id}.report.json")),
        &report,
    )?;
    Ok(report)
}

fn quote(s: &str) -> String {
    format!(
        "\"{}\"",
        s.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('$', "\\$")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
    )
}
pub fn render(plan: &Plan, hub: bool) -> Result<String> {
    let side = if hub { "hub" } else { "site" };
    let ops = model(plan)?;
    let mut out=String::from("# Generated by wgtun. Review; import through independent access in Safe Mode.\n# Interfaces and private keys are never created or changed.\n");
    for op in ops.iter().filter(|o| o.device() == side) {
        match op {
            Operation::CheckInterface{interface,expect_public_key,..}=>out.push_str(&format!(":if ([:len [/interface/wireguard/find where name={} public-key={} disabled=no]] != 1) do={{ :error \"wgtun: interface precondition\" }}\n",quote(interface),quote(expect_public_key))),
            _=> {
                let (path,want)=op.desired().unwrap();
                let cli=path.trim_start_matches("/rest");
                out.push_str(&format!("{cli}/remove [find where interface={} comment={}]\n{cli}/add",quote(text(&want,"interface")),quote(text(&want,"comment"))));
                for (k,v) in want.as_object().unwrap() { out.push_str(&format!(" {k}={}",quote(v.as_str().unwrap()))); }
                out.push('\n');
            }
        }
    }
    out.push_str("# Verify peer state, routes, DNS, Internet and a fresh management reconnect.\n");
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hash_is_recursive_and_order_independent() {
        assert_eq!(
            hash(&json!({"b":{"z":1,"a":2},"a":[2,1]})),
            hash(&json!({"a":[2,1],"b":{"a":2,"z":1}}))
        );
        assert_ne!(hash(&json!([1, 2])), hash(&json!([2, 1])));
    }
    #[test]
    fn normalize_routeros_types_and_omit_secrets() {
        let value = project(
            &json!({"interface":"wg1","public-key":"public","private-key":"secret","preshared-key":"secret","allowed-address":"192.168.1.0/24, 10.0.0.2/32","persistent-keepalive":"00:00:25","rx":"999","last-handshake":"1s"}),
            PEER,
        );
        assert_eq!(value["allowed-address"], "10.0.0.2/32,192.168.1.0/24");
        assert_eq!(value["persistent-keepalive"], "25");
        assert!(!value.to_string().contains("secret"));
        assert!(value.get("rx").is_none());
    }
    #[test]
    fn script_escaping_does_not_expand_variables() {
        assert_eq!(quote("a\"$b\\c"), "\"a\\\"\\$b\\\\c\"");
    }
    #[test]
    fn keys_are_real_wireguard_public_keys() {
        assert!(!key_valid("REPLACE_WITH_HUB_PUBLIC_KEY"));
        assert!(!key_valid("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
        assert!(key_valid("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="));
    }
}

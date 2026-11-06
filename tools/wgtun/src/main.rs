mod executor;
use anyhow::{anyhow, bail, Context, Result};
use clap::{Args, Parser, Subcommand};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    env, fs,
    net::Ipv4Addr,
    path::{Path, PathBuf},
    time::Duration,
};

#[derive(Parser)]
#[command(
    name = "wgtun",
    about = "Plan RouterOS WireGuard hub-and-site tunnels",
    version
)]
struct Cli {
    /// Emit one stable JSON object on stdout.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Check local configuration and optionally a RouterOS REST endpoint.
    Doctor {
        #[arg(long)]
        profile: Option<String>,
    },
    /// Create an empty local configuration file without credentials.
    Init,
    /// Inspect configured RouterOS profiles.
    Profiles {
        #[command(subcommand)]
        command: ProfilesCommand,
    },
    /// Read RouterOS interface and address inventory.
    Nodes {
        #[command(subcommand)]
        command: NodesCommand,
    },
    /// Validate or render a two-router tunnel plan.
    Plan {
        #[command(subcommand)]
        command: PlanCommand,
    },
    /// Read both targets and persist a confirmation-bound preview (no writes).
    Preview {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// Execute a persisted preview after rechecking both targets.
    Apply {
        #[arg(long)]
        preview: PathBuf,
        #[arg(long)]
        confirm: String,
        #[arg(long)]
        operation_id: String,
    },
    /// Read-only RouterOS REST escape hatch. Only GET is accepted.
    Request(RequestArgs),
}

#[derive(Subcommand)]
enum ProfilesCommand {
    List,
}

#[derive(Subcommand)]
enum NodesCommand {
    List(ProfileArgs),
    Get(ProfileArgs),
    Resolve {
        #[command(flatten)]
        profile: ProfileArgs,
        #[arg(long)]
        interface: String,
    },
}

#[derive(Subcommand)]
enum PlanCommand {
    Validate {
        #[arg(long)]
        file: PathBuf,
    },
    Render {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// Show that live apply is intentionally unavailable in v0.1.
    Apply {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        dry_run: bool,
    },
}

#[derive(Args)]
struct ProfileArgs {
    #[arg(long)]
    profile: String,
}

#[derive(Args)]
struct RequestArgs {
    #[arg(value_parser = ["get"])]
    method: String,
    #[arg(long)]
    profile: String,
    path: String,
}

#[derive(Debug, Default, Deserialize)]
struct Config {
    #[serde(default)]
    profiles: std::collections::BTreeMap<String, Profile>,
}

#[derive(Debug, Default, Deserialize, Clone)]
struct Profile {
    url: Option<String>,
    username: Option<String>,
    password: Option<String>,
    #[serde(default)]
    insecure_tls: bool,
    management_interface: Option<String>,
    #[serde(default)]
    independent_path_verified: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Plan {
    version: u8,
    tag: String,
    hub: Hub,
    site: Site,
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Hub {
    profile: String,
    interface: String,
    address: String,
    listen_port: u16,
    public_key: String,
    allowed_addresses: Vec<String>,
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Site {
    profile: String,
    interface: String,
    address: String,
    endpoint: String,
    public_key: String,
    keepalive_seconds: u16,
    lan_networks: Vec<String>,
    allowed_addresses: Vec<String>,
}

fn config_path() -> PathBuf {
    env::var_os("WGTUN_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".wgtun/config.toml")
        })
}

fn read_config() -> Result<Config> {
    let path = config_path();
    if !path.exists() {
        return Ok(Config::default());
    }
    toml::from_str(&fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?)
        .with_context(|| format!("parse {}", path.display()))
}

fn profile_env(profile: &str, key: &str) -> Option<String> {
    let normalized = profile.to_ascii_uppercase().replace('-', "_");
    env::var(format!("WGTUN_{normalized}_{key}"))
        .ok()
        .filter(|value| !value.is_empty())
}

fn resolved_profile(name: &str) -> Result<(String, String, String, bool, &'static str)> {
    let config = read_config()?;
    let from_config = config.profiles.get(name).cloned().unwrap_or_default();
    let url = profile_env(name, "URL")
        .or(from_config.url)
        .ok_or_else(|| anyhow!("profile '{name}' has no URL"))?;
    let username = profile_env(name, "USERNAME")
        .or(from_config.username)
        .ok_or_else(|| anyhow!("profile '{name}' has no username"))?;
    let password_env = profile_env(name, "PASSWORD");
    let auth_source = if password_env.is_some() {
        "env"
    } else if from_config.password.is_some() {
        "config"
    } else {
        "missing"
    };
    let password = password_env.or(from_config.password).ok_or_else(|| {
        anyhow!(
            "profile '{name}' has no password; set WGTUN_{}_PASSWORD",
            name.to_ascii_uppercase().replace('-', "_")
        )
    })?;
    if !url.starts_with("https://") && !url.starts_with("http://") {
        bail!("profile '{name}' URL must start with http:// or https://");
    }
    Ok((
        url.trim_end_matches('/').to_owned(),
        username,
        password,
        from_config.insecure_tls,
        auth_source,
    ))
}

fn rest_get(profile: &str, path: &str) -> Result<Value> {
    if !path.starts_with("/rest/") {
        bail!("path must begin with /rest/");
    }
    let (base, username, password, insecure_tls, _) = resolved_profile(profile)?;
    let url = format!("{base}{path}");
    let client = Client::builder()
        .timeout(Duration::from_secs(12))
        .danger_accept_invalid_certs(insecure_tls)
        .build()?;
    let response = client
        .get(url)
        .basic_auth(username, Some(password))
        .send()
        .context("RouterOS REST request failed")?;
    let status = response.status();
    let text = response.text()?;
    if !status.is_success() {
        bail!(
            "RouterOS REST returned HTTP {status}: {}",
            text.chars().take(300).collect::<String>()
        );
    }
    serde_json::from_str(&text).context("RouterOS returned non-JSON response")
}

fn read_plan(path: &Path) -> Result<Plan> {
    let plan: Plan = serde_yaml::from_str(
        &fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?,
    )
    .with_context(|| format!("parse {}", path.display()))?;
    executor::validate(&plan)?;
    Ok(plan)
}

fn parse_network(input: &str) -> Result<(u32, u8)> {
    let (address, prefix) = input
        .split_once('/')
        .ok_or_else(|| anyhow!("'{input}' must use CIDR notation"))?;
    let ip: Ipv4Addr = address
        .parse()
        .with_context(|| format!("invalid IPv4 address '{address}'"))?;
    let prefix: u8 = prefix
        .parse()
        .with_context(|| format!("invalid prefix in '{input}'"))?;
    if prefix > 32 {
        bail!("invalid prefix in '{input}'");
    }
    let mask = if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    };
    Ok((u32::from(ip) & mask, prefix))
}

fn networks_overlap(a: &str, b: &str) -> Result<bool> {
    let (a_base, a_prefix) = parse_network(a)?;
    let (b_base, b_prefix) = parse_network(b)?;
    let common = a_prefix.min(b_prefix);
    let mask = if common == 0 {
        0
    } else {
        u32::MAX << (32 - common)
    };
    Ok((a_base & mask) == (b_base & mask))
}

fn host_cidr(cidr: &str) -> Result<String> {
    let (host, _) = cidr
        .split_once('/')
        .ok_or_else(|| anyhow!("'{cidr}' must use CIDR notation"))?;
    let _: Ipv4Addr = host.parse()?;
    Ok(format!("{host}/32"))
}

fn validate_plan(plan: &Plan) -> Result<()> {
    if plan.version != 1 {
        bail!("only plan version 1 is supported");
    }
    if !plan.tag.starts_with("WGTUN:") {
        bail!("tag must begin with WGTUN:");
    }
    if plan.hub.interface.is_empty() || plan.site.interface.is_empty() {
        bail!("WireGuard interface names cannot be empty");
    }
    if plan.hub.public_key.contains("REPLACE_WITH_")
        || plan.site.public_key.contains("REPLACE_WITH_")
    {
        bail!("plan contains a placeholder public key");
    }
    parse_network(&plan.hub.address)?;
    parse_network(&plan.site.address)?;
    if host_cidr(&plan.hub.address)? == host_cidr(&plan.site.address)? {
        bail!("HUB and site tunnel addresses must differ");
    }
    let mut seen = HashSet::new();
    for network in plan
        .site
        .lan_networks
        .iter()
        .chain(plan.hub.allowed_addresses.iter())
        .chain(plan.site.allowed_addresses.iter())
    {
        parse_network(network)?;
        if !seen.insert(network) {
            bail!("network '{network}' appears more than once");
        }
    }
    for (index, left) in plan.site.lan_networks.iter().enumerate() {
        for right in plan.site.lan_networks.iter().skip(index + 1) {
            if networks_overlap(left, right)? {
                bail!("site LAN networks overlap: '{left}' and '{right}'");
            }
        }
    }
    Ok(())
}

fn render_rsc(plan: &Plan, hub: bool) -> Result<String> {
    executor::render(plan, hub)
}

fn run(cli: Cli) -> Result<Value> {
    match cli.command {
        Command::Preview { file, out } => executor::preview_file(&file, &out),
        Command::Apply {
            preview,
            confirm,
            operation_id,
        } => executor::apply_file(&preview, &confirm, &operation_id),
        Command::Doctor { profile } => {
            let config_exists = config_path().exists();
            let mut data = json!({"version": env!("CARGO_PKG_VERSION"), "config_path": config_path(), "config_exists": config_exists, "profile": profile});
            if let Some(name) = data["profile"].as_str() {
                match resolved_profile(name) {
                    Ok((base, _, _, insecure_tls, auth_source)) => {
                        let reachable = rest_get(name, "/rest/system/resource").is_ok();
                        data["profile_status"] = json!({"url": base, "auth_source": auth_source, "insecure_tls": insecure_tls, "reachable": reachable});
                    }
                    Err(error) => {
                        data["profile_status"] =
                            json!({"configured": false, "reason": error.to_string()})
                    }
                }
            }
            Ok(data)
        }
        Command::Init => {
            let path = config_path();
            if path.exists() {
                bail!("{} already exists; refusing to overwrite", path.display());
            }
            fs::create_dir_all(path.parent().unwrap())?;
            fs::write(&path, "# Store URLs and usernames here. Set passwords through WGTUN_<PROFILE>_PASSWORD.\n[profiles]\n")?;
            Ok(json!({"created": path, "credentials_written": false}))
        }
        Command::Profiles {
            command: ProfilesCommand::List,
        } => {
            let config = read_config()?;
            Ok(
                json!({"profiles": config.profiles.into_iter().map(|(name, profile)| json!({"name": name, "url": profile.url, "username_configured": profile.username.is_some(), "password_configured": profile.password.is_some(), "insecure_tls": profile.insecure_tls})).collect::<Vec<_>>() }),
            )
        }
        Command::Nodes { command } => match command {
            NodesCommand::List(args) | NodesCommand::Get(args) => Ok(
                json!({"interfaces": rest_get(&args.profile, "/rest/interface")?, "addresses": rest_get(&args.profile, "/rest/ip/address")?}),
            ),
            NodesCommand::Resolve { profile, interface } => {
                let interfaces = rest_get(&profile.profile, "/rest/interface")?;
                let item = interfaces
                    .as_array()
                    .and_then(|items| {
                        items.iter().find(|item| {
                            item.get("name").and_then(Value::as_str) == Some(interface.as_str())
                        })
                    })
                    .cloned();
                Ok(json!({"interface": item, "found": item.is_some()}))
            }
        },
        Command::Plan { command } => match command {
            PlanCommand::Validate { file } => {
                let plan = read_plan(&file)?;
                Ok(
                    json!({"valid": true, "tag": plan.tag, "hub_profile": plan.hub.profile, "site_profile": plan.site.profile}),
                )
            }
            PlanCommand::Render { file, out } => {
                let plan = read_plan(&file)?;
                fs::create_dir_all(&out)?;
                let hub_path = out.join("hub.rsc");
                let site_path = out.join("site.rsc");
                fs::write(&hub_path, render_rsc(&plan, true)?)?;
                fs::write(&site_path, render_rsc(&plan, false)?)?;
                Ok(
                    json!({"hub": hub_path, "site": site_path, "tag": plan.tag, "apply": "Import each file only through an independently safe management path and RouterOS Safe Mode."}),
                )
            }
            PlanCommand::Apply { file, dry_run } => {
                let plan = read_plan(&file)?;
                if !dry_run {
                    bail!("live apply is unavailable in v0.1; use plan render, review, and import in Safe Mode");
                }
                Ok(
                    json!({"dry_run": true, "tag": plan.tag, "writes": 0, "next": "wgtun plan render --file ... --out ..."}),
                )
            }
        },
        Command::Request(args) => Ok(rest_get(&args.profile, &args.path)?),
    }
}

fn main() {
    let cli = Cli::parse();
    let json_mode = cli.json;
    match run(cli) {
        Ok(data) => println!(
            "{}",
            serde_json::to_string_pretty(&json!({"ok": true, "data": data})).unwrap()
        ),
        Err(error) => {
            if json_mode {
                println!("{}", serde_json::to_string(&json!({"ok": false, "error": {"code": executor::error_code(&error), "message": error.to_string()}})).unwrap());
            } else {
                eprintln!("wgtun: {error:#}");
            }
            std::process::exit(1);
        }
    }
}

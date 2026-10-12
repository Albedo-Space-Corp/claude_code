# /// script
# requires-python = ">=3.11"
# dependencies = ["tomlkit==0.13.3"]
# ///
"""Shared configuration for the macOS/Linux and Windows Codex installers."""

import configparser
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

import tomlkit


AWS_BLOCK = """[sso-session albedo-commercial]
sso_start_url = https://albedo.awsapps.com/start
sso_region = us-west-2
sso_registration_scopes = sso:account:access

[profile prod-it01-bedrock]
sso_session = albedo-commercial
sso_account_id = 188343044386
sso_role_name = AlbedoBedrockUsers
region = us-west-2
output = json

[sso-session albedo-gc]
sso_start_url = https://start.us-gov-home.awsapps.com/directory/albedo-gc
sso_region = us-gov-west-1
sso_registration_scopes = sso:account:access

[profile gc-prod-it01-bedrock]
sso_session = albedo-gc
sso_account_id = 479469912381
sso_role_name = AlbedoBedrockUsers
region = us-gov-west-1
output = json
"""
MARKETPLACE_URL = "https://git-codecommit.us-west-2.amazonaws.com/v1/repos/albedo-plugins.git"

# Bedrock Runtime serves GPT through US cross-Region inference profiles
# (us.openai.*) under the bedrock:InvokeModel permissions.
RUNTIME_PROVIDER = "amazon-bedrock-runtime"
LEGACY_PROVIDER = "amazon-bedrock"
COMMERCIAL_BEDROCK = {"aws": {"profile": "prod-it01-bedrock", "region": "us-west-2"}}

# Bedrock model IDs are literals: the provider has no `opus`/`sonnet`-style
# aliases to resolve a tier at request time, so the default is whatever is
# written here.
#
# SUPERSEDED holds every model this installer has previously written as the
# default. Setup replaces one it finds, so bumping the pin reaches installations
# that already exist; any other model was chosen by the user and is left alone.
# Without the list a pin is a one-shot initial value that can never move, since
# the first run makes every later run a no-op. When the pin changes, append the
# old value here in the same commit.
COMMERCIAL_MODEL = "us.openai.gpt-6.1-sol"
COMMERCIAL_EFFORT_LEVEL = "medium"
SUPERSEDED_COMMERCIAL_MODELS = ("openai.gpt-6-astra", "openai.gpt-6.1-sol")


def pin_model(config, key, pin, superseded):
    """Set an absent or superseded installer default to the current pin."""
    if key in config and str(config[key]) in superseded:
        del config[key]
    if key not in config:
        config[key] = pin


def model_selections(text):
    """Return the model choices a Codex config makes, for reporting changes."""
    config = tomlkit.parse(text)
    picked = {key: str(config[key]) for key in ("model", "review_model") if key in config}
    agents = config.get("agents", {})
    if "default_subagent_model" in agents:
        picked["agents.default_subagent_model"] = str(agents["default_subagent_model"])
    return picked


def aws_settings(text):
    """Replace the four Albedo sections, as setup_ccb.sh does, keeping the rest."""
    remainder = []
    skip = False
    for line in text.splitlines(keepends=True):
        if re.match(r"\s*\[", line):
            skip = bool(re.match(
                r"\s*\[(?:profile\s+(?:prod-it01-bedrock|gc-prod-it01-bedrock)"
                r"|sso-session\s+(?:albedo-commercial|albedo-gc))\]\s*(?:[#;].*)?$",
                line,
            ))
        if not skip or re.match(r"\s*[#;]", line):
            remainder.append(line)
    rest = "".join(remainder).strip("\r\n")
    result = AWS_BLOCK + ("\n" + rest + "\n" if rest else "")
    # Reject malformed or duplicate sections before touching either config file.
    configparser.RawConfigParser().read_string(result)
    return result


def codex_settings(text):
    """Return config.toml text and the unsupported legacy settings removed."""
    config = tomlkit.parse(text)
    removed = []
    # Codex cannot run with these unsupported legacy GovCloud settings.
    profiles = config.get("profiles")
    if profiles is not None and "gov" in profiles:
        del profiles["gov"]
        removed.append("[profiles.gov]")
        if not profiles:
            del config["profiles"]
    if config.get("profile") == "gov":
        del config["profile"]
        removed.append('profile = "gov"')
    config["model_provider"] = RUNTIME_PROVIDER
    config["service_tier"] = "default"
    # Runtime has no hosted web search; Codex fails requests that ask for it.
    config["web_search"] = "disabled"
    # Runtime serves only cross-Region profiles, and IAM denies global.*, so
    # only us.* selections survive. Bare ChatGPT and openai.* IDs fail on
    # Runtime and are dropped.
    agents = config.get("agents", {})
    for table, key in ((config, "model"), (config, "review_model"), (agents, "default_subagent_model")):
        if key in table and not str(table[key]).startswith("us."):
            del table[key]
    # Only `model` is pinned; review and subagent selections fall back to it.
    pin_model(config, "model", COMMERCIAL_MODEL, SUPERSEDED_COMMERCIAL_MODELS)
    pin_model(config, "model_reasoning_effort", COMMERCIAL_EFFORT_LEVEL, ())
    providers = config.setdefault("model_providers", tomlkit.table())
    # The provider derives its Runtime endpoint from the region.
    if providers.get(RUNTIME_PROVIDER) != COMMERCIAL_BEDROCK:
        providers[RUNTIME_PROVIDER] = COMMERCIAL_BEDROCK
    # Earlier setups wrote this table for the Mantle provider. Remove it only if
    # it is exactly what setup wrote, so a user's own settings survive.
    if providers.get(LEGACY_PROVIDER) == COMMERCIAL_BEDROCK:
        del providers[LEGACY_PROVIDER]
    marketplaces = config.setdefault("marketplaces", tomlkit.table())
    marketplace = {"source_type": "git", "source": MARKETPLACE_URL}
    if marketplaces.get("albedo-claude-plugin-marketplace") != marketplace:
        marketplaces["albedo-claude-plugin-marketplace"] = marketplace
    return tomlkit.dumps(config), removed


def write_configs(configs):
    """Stage every file before replacing any; restore originals on write failure."""
    staged = []
    applied = []
    try:
        for path, text in configs:
            previous = path.read_text(encoding="utf-8-sig") if path.exists() else None
            if previous == text:
                print(f"Unchanged: {path}")
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
            temporary = Path(temporary)
            staged.append((path, temporary, None))
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(text)
            backup = None
            if previous is not None:
                backup = path.with_name(f"{path.name}.bak.{time.time_ns()}")
                shutil.copy2(path, backup)
                print(f"Backup: {backup}")
            staged[-1] = (path, temporary, backup)
        for path, temporary, backup in staged:
            os.replace(temporary, path)
            applied.append((path, temporary, backup))
    except Exception as error:
        rollback_errors = []
        for path, temporary, backup in reversed(applied):
            try:
                if backup is None:
                    path.unlink()
                else:
                    shutil.copy2(backup, temporary)
                    os.replace(temporary, path)
            except OSError as rollback_error:
                rollback_errors.append(f"{path}: {rollback_error}; backup: {backup}")
        if rollback_errors:
            raise RuntimeError("Configuration failed and rollback was incomplete: " +
                               "; ".join(rollback_errors)) from error
        raise
    finally:
        for _, temporary, _ in staged:
            temporary.unlink(missing_ok=True)
    for path, _, _ in applied:
        print(f"Configured: {path}")
    return [path for path, _, _ in applied]


def configure(aws_config, codex_config):
    """Write AWS profiles and config.toml; return whether Codex's config changed."""
    def read(path):
        return path.read_text(encoding="utf-8-sig") if path.exists() else ""

    # Parse both before writing, so invalid TOML leaves AWS configuration alone.
    old_codex = read(codex_config)
    new_aws = aws_settings(read(aws_config))
    new_codex, removed = codex_settings(old_codex)
    changed = write_configs(((aws_config, new_aws), (codex_config, new_codex)))
    # Report after writing, so rollback never announces a change that did not land.
    if removed:
        print(f"{codex_config.name}: removed " + ", ".join(removed))
    before, after = model_selections(old_codex), model_selections(new_codex)
    for key in sorted(before.keys() | after.keys()):
        was, now = before.get(key), after.get(key)
        if was is not None and was != now:
            print(f"{codex_config.name}: {key} was {was}, now {now or 'unset (follows model)'}")
    return codex_config in changed


def restart_daemon():
    """Restart the shared Codex app-server daemon if one is running.

    The daemon reads config.toml only when it starts, and sessions get their
    model list from it, so a daemon started before a config change keeps
    offering the old provider's models, and `/model` then writes their IDs back
    into the config. A restart interrupts the daemon's sessions, so it is done
    only after setup changed config.toml.
    """
    status = subprocess.run(["codex", "app-server", "daemon", "version"], capture_output=True, text=True)
    try:
        running = status.returncode == 0 and json.loads(status.stdout)["status"] == "running"
    except (ValueError, KeyError):
        running = False
    if not running:
        return
    print("Restarting the Codex background server to load the new configuration...")
    restart = subprocess.run(["codex", "app-server", "daemon", "restart"], capture_output=True, text=True)
    if restart.returncode != 0:
        print(f"Warning: could not restart the Codex background server: {restart.stderr.strip()}\n"
              "Run `codex app-server daemon restart` before using /model.")


def configure_git():
    # Reset inherited credential stores only for this repository. An expired
    # cached password must not take precedence over the AWS credential helper.
    section = f"credential.{MARKETPLACE_URL}"
    for args in (
        [section + ".UseHttpPath", "true"],
        ["--replace-all", section + ".helper", ""],
        ["--add", section + ".helper", "!aws --profile prod-it01-bedrock codecommit credential-helper $@"],
    ):
        subprocess.run(["git", "config", "--global", *args], check=True)


def check_versions():
    for command, pattern, minimum, update in (
        ("aws", r"aws-cli/(\d+)\.(\d+)\.(\d+)", (2, 9, 0), "update AWS CLI v2"),
        ("codex", r"codex-cli (\d+)\.(\d+)\.(\d+)", (0, 154, 0), "run codex update"),
    ):
        version = subprocess.check_output([command, "--version"], text=True, stderr=subprocess.STDOUT)
        match = re.search(pattern, version)
        if not match or tuple(map(int, match.groups())) < minimum:
            required = ".".join(map(str, minimum))
            raise SystemExit(f"This setup requires {command} {required}+; {update}, then rerun setup.")


if __name__ == "__main__":
    check_versions()
    user_dir = Path.home()
    aws_path = Path(os.environ.get("AWS_CONFIG_FILE", user_dir / ".aws/config"))
    codex_dir = Path(os.environ.get("CODEX_HOME", user_dir / ".codex"))
    codex_changed = configure(aws_path, codex_dir / "config.toml")
    configure_git()
    if codex_changed:
        restart_daemon()

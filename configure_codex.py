# /// script
# requires-python = ">=3.11"
# dependencies = ["tomlkit==0.13.3"]
# ///
"""Shared configuration for the macOS/Linux and Windows Codex installers."""

import configparser
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

# `codex --profile gov` layers gov.config.toml over config.toml. The gov Mantle
# endpoint must be set explicitly (the provider derives only commercial
# endpoints from its region), and on the /openai/v1 path: /v1 rejects the
# request body Codex sends.
GOV_PROVIDER = {
    "base_url": "https://bedrock-mantle.us-gov-west-1.api.aws/openai/v1",
    "aws": {"profile": "gc-prod-it01-bedrock", "region": "us-gov-west-1"},
}
# Bedrock model IDs are literals: the provider has no `opus`/`sonnet`-style
# aliases to resolve a tier at request time, so the default tier is whatever is
# written here. Each partition gets the strongest Mantle model it serves. Within
# a generation the tiers rank Sol > Terra > Luna, and GovCloud carries neither
# Sol nor any GPT-6, so the two partitions cannot share a pin.
#
# SUPERSEDED holds every model this installer has previously written as that
# partition's default. Setup replaces one it finds, so bumping a pin reaches
# installations that already exist; a model outside both lists was chosen by the
# user and is left alone. Without the lists a pin is a one-shot initial value
# that can never move, since the first run makes every later run a no-op. When a
# pin changes, append the old value here in the same commit.
COMMERCIAL_MODEL = "openai.gpt-6.1-sol"
SUPERSEDED_COMMERCIAL_MODELS = ()
GOV_MODEL = "openai.gpt-5.6-terra"
SUPERSEDED_GOV_MODELS = ("openai.gpt-5.6-luna",)


def pin_model(config, key, pin, superseded, add=True):
    """Set `key` to `pin`, replacing a default this installer used to write.

    Clearing a superseded value is unconditional, because a stale one left in an
    overlay outranks the current pin for that key. `add` is false where the
    overlay has no base selection to shadow: the key is cleared and left absent
    so it follows `model`.
    """
    if key in config and str(config[key]) in superseded:
        del config[key]
    if add and key not in config:
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
    """Return the commercial config.toml text and any legacy gov profile table.

    Codex refuses `--profile gov` while config.toml holds a `[profiles.gov]`
    table or a `profile = "gov"` selector, so both are removed here and the
    table's contents move into gov.config.toml.
    """
    config = tomlkit.parse(text)
    legacy_gov = {}
    profiles = config.get("profiles")
    if profiles is not None and "gov" in profiles:
        legacy_gov = profiles["gov"].unwrap()
        del profiles["gov"]
        if not profiles:
            del config["profiles"]
    if config.get("profile") == "gov":
        del config["profile"]
    config["model_provider"] = "amazon-bedrock"
    config["service_tier"] = "default"
    # ChatGPT model IDs aren't Bedrock IDs, so drop any that Bedrock cannot
    # serve while keeping a model the user already selected on Bedrock.
    for key in ("model", "review_model"):
        if key in config and not str(config[key]).startswith("openai."):
            del config[key]
    agents = config.get("agents", {})
    if "default_subagent_model" in agents and not str(agents["default_subagent_model"]).startswith("openai."):
        del agents["default_subagent_model"]
    # Only `model` is pinned; review and subagent selections fall back to it.
    pin_model(config, "model", COMMERCIAL_MODEL, SUPERSEDED_COMMERCIAL_MODELS)
    providers = config.setdefault("model_providers", tomlkit.table())
    # Commercial needs only the AWS profile and region; the provider derives its
    # Mantle endpoint from the region.
    bedrock = {"aws": {"profile": "prod-it01-bedrock", "region": "us-west-2"}}
    if providers.get("amazon-bedrock") != bedrock:
        providers["amazon-bedrock"] = bedrock
    marketplaces = config.setdefault("marketplaces", tomlkit.table())
    marketplace = {"source_type": "git", "source": MARKETPLACE_URL}
    if marketplaces.get("albedo-claude-plugin-marketplace") != marketplace:
        marketplaces["albedo-claude-plugin-marketplace"] = marketplace
    return tomlkit.dumps(config), legacy_gov


def _fill_missing(target, source):
    """Copy keys from source that target lacks, merging nested tables.

    Existing values in target win, so a user's gov.config.toml is never
    overwritten; nested tables such as [mcp_servers] merge key by key so no
    legacy entry is dropped.
    """
    for key, value in source.items():
        if key not in target:
            target[key] = value
        elif isinstance(value, dict) and isinstance(target[key], dict):
            _fill_missing(target[key], value)


def gov_codex_settings(text, base_text, legacy_gov=None):
    """Set the GovCloud provider overlay, keeping anything else the user added.

    Keys from a migrated legacy `[profiles.gov]` table fill in only what the
    file doesn't already set. Model selections the overlay would inherit from
    config.toml are pinned to a gov-served model unless the user chose one here;
    a superseded default this installer wrote counts as unchosen.
    """
    config = tomlkit.parse(text)
    _fill_missing(config, legacy_gov or {})
    base = tomlkit.parse(base_text)
    pin_model(config, "model", GOV_MODEL, SUPERSEDED_GOV_MODELS)
    pin_model(config, "review_model", GOV_MODEL, SUPERSEDED_GOV_MODELS,
              add="review_model" in base)
    base_agents = base.get("agents", {})
    agents = config.get("agents")
    if "default_subagent_model" in base_agents:
        agents = config.setdefault("agents", tomlkit.table())
    if agents is not None:
        # A table the clear empties is left in place. tomlkit reports a
        # comment-only table as empty, so dropping empty tables would delete
        # comments from an `[agents]` table setup never touched.
        pin_model(agents, "default_subagent_model", GOV_MODEL, SUPERSEDED_GOV_MODELS,
                  add="default_subagent_model" in base_agents)
    providers = config.setdefault("model_providers", tomlkit.table())
    if providers.get("amazon-bedrock") != GOV_PROVIDER:
        providers["amazon-bedrock"] = GOV_PROVIDER
    return tomlkit.dumps(config)


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


def configure(aws_config, codex_config):
    gov_config = codex_config.with_name("gov.config.toml")

    def read(path):
        return path.read_text(encoding="utf-8-sig") if path.exists() else ""

    # Parse all three before writing, so invalid TOML leaves AWS configuration alone.
    old_codex, old_gov = read(codex_config), read(gov_config)
    new_aws = aws_settings(read(aws_config))
    new_codex, legacy_gov = codex_settings(old_codex)
    new_gov = gov_codex_settings(old_gov, new_codex, legacy_gov)
    write_configs(((aws_config, new_aws), (codex_config, new_codex), (gov_config, new_gov)))
    # Advancing a superseded default replaces a value the user may have set by
    # hand, so report it rather than let it be a surprise. Reported after the
    # write, so a rollback never announces a change that did not land.
    for path, before, after in ((codex_config, old_codex, new_codex), (gov_config, old_gov, new_gov)):
        before, after = model_selections(before), model_selections(after)
        for key in sorted(before.keys() | after.keys()):
            was, now = before.get(key), after.get(key)
            if was is not None and was != now:
                print(f"{path.name}: {key} was {was}, now {now or 'unset (follows model)'}")


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
    configure(aws_path, codex_dir / "config.toml")
    configure_git()

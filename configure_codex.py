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
"""
MARKETPLACE_URL = "https://git-codecommit.us-west-2.amazonaws.com/v1/repos/albedo-plugins.git"


def aws_settings(text):
    """Replace only the two commercial sections, as in the Claude installers."""
    remainder = []
    skip = False
    for line in text.splitlines(keepends=True):
        if re.match(r"\s*\[", line):
            skip = bool(re.match(
                r"\s*\[(?:profile\s+prod-it01-bedrock|sso-session\s+albedo-commercial)\]\s*(?:[#;].*)?$",
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
    config = tomlkit.parse(text)
    config["model_provider"] = "amazon-bedrock"
    config["service_tier"] = "default"
    # ChatGPT model IDs aren't Bedrock IDs. Let the native picker choose its
    # default, while keeping any model the user already selected on Bedrock.
    for key in ("model", "review_model"):
        if key in config and not str(config[key]).startswith("openai."):
            del config[key]
    agents = config.get("agents", {})
    if "default_subagent_model" in agents and not str(agents["default_subagent_model"]).startswith("openai."):
        del agents["default_subagent_model"]
    providers = config.setdefault("model_providers", tomlkit.table())
    # The built-in provider accepts only AWS profile/region overrides.
    bedrock = {"aws": {"profile": "prod-it01-bedrock", "region": "us-west-2"}}
    if providers.get("amazon-bedrock") != bedrock:
        providers["amazon-bedrock"] = bedrock
    marketplaces = config.setdefault("marketplaces", tomlkit.table())
    marketplace = {"source_type": "git", "source": MARKETPLACE_URL}
    if marketplaces.get("albedo-claude-plugin-marketplace") != marketplace:
        marketplaces["albedo-claude-plugin-marketplace"] = marketplace
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
    aws_text = aws_config.read_text(encoding="utf-8-sig") if aws_config.exists() else ""
    codex_text = codex_config.read_text(encoding="utf-8-sig") if codex_config.exists() else ""
    # Parse both before writing, so invalid TOML leaves AWS configuration alone.
    new_aws = aws_settings(aws_text)
    new_codex = codex_settings(codex_text)
    write_configs(((aws_config, new_aws), (codex_config, new_codex)))


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

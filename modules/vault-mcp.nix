{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;

  vaultMcpSrc = pkgs.callPackage ../pkgs/vault-mcp.nix { };

  python = pkgs.python311;

  # pip-installed binary wheels (numpy, torch, ...) link against the system
  # libstdc++ etc. Pure NixOS doesn't expose those, so set LD_LIBRARY_PATH.
  wheelLibPath = lib.makeLibraryPath (with pkgs; [
    stdenv.cc.cc.lib
    zlib
    glib
    openssl
  ]);

  # vault-mcp only supports a single source dir (paths.vault_dir) and a
  # hardcoded ChromaDB backend — no [vector_store] / [[sources]]. Pick the
  # vault: explicit obsidianVault wins, else the first indexDirectories entry.
  vaultDir =
    if cfg.obsidianVault != null then toString cfg.obsidianVault
    else if cfg.indexDirectories != [ ] then toString (builtins.head cfg.indexDirectories)
    else throw "services.mneme: set obsidianVault or at least one indexDirectories entry";

  vaultType = if cfg.obsidianVault != null then "Obsidian" else "Standard";

  # vault-mcp's loader does `open(os.path.join(config_path, "app.toml"))`,
  # so --config must point at a *directory* containing app.toml.
  appConfigDir = pkgs.writeTextDir "app.toml" ''
    [paths]
    vault_dir = "${vaultDir}"
    database_dir = "${cfg.stateDir}/vault-mcp/chroma_db"
    data_dir = "${cfg.stateDir}/vault-mcp/data"
    type = "${vaultType}"

    [server]
    host = "127.0.0.1"
    api_port = ${toString cfg.ports.api}
    mcp_port = ${toString cfg.ports.mcp}

    [embedding_model]
    provider = "openai_endpoint"
    model_name = "embeddings"
    endpoint_url = "http://127.0.0.1:${toString cfg.ports.openvino}/v1"
    api_key = "unused"

    [retrieval]
    # "static" avoids requiring a generation_model. Switch to "agentic" and
    # add a [generation_model] block to enable LLM-mediated retrieval.
    mode = "static"

    [watcher]
    enabled = true
    debounce_seconds = 2
  '';

  # Bootstrap script: idempotently builds a venv at $VENV using upstream's
  # install_deps.sh logic, then installs the project in editable mode.
  # Runs as ExecStartPre. Needs network on first invocation. The stamp
  # combines the source rev with the bootstrap derivation hash, so any
  # change to the bootstrap script auto-invalidates the venv.
  bootstrap = pkgs.writeShellApplication {
    name = "mneme-vault-mcp-bootstrap";
    runtimeInputs = [ python pkgs.gnused pkgs.coreutils ];
    text = ''
      set -euo pipefail
      VENV="$1"
      SRC_RO="${vaultMcpSrc}/share/vault-mcp"
      WORK="${cfg.stateDir}/vault-mcp/build"
      STAMP="${vaultMcpSrc.version}+bootstrap=$(basename "$0")"

      if [ -x "$VENV/bin/vault-mcp" ] && [ -f "$VENV/.mneme-rev" ] \
         && [ "$(cat "$VENV/.mneme-rev")" = "$STAMP" ]; then
        exit 0
      fi

      echo "[mneme] First-time setup of vault-mcp venv at $VENV (5–10 min)..."
      rm -rf "$VENV" "$WORK"
      mkdir -p "$WORK"
      cp -rT "$SRC_RO" "$WORK"
      chmod -R u+w "$WORK"

      # mlx-lm is Apple-Silicon-only; remove it before installing.
      sed -i '/^[[:space:]]*"mlx-lm/d' "$WORK/pyproject.toml"

      # Upstream's pyproject only packages `components` and `shared` into the
      # wheel, but the entrypoint script does `from vault_mcp.main import run`.
      # Add the missing top-level packages so the install is actually usable.
      sed -i \
        's|^packages = \["components", "shared"\]|packages = ["components", "shared", "vault_mcp", "plugins"]|' \
        "$WORK/pyproject.toml"

      ${python}/bin/python -m venv "$VENV"
      "$VENV/bin/pip" install --upgrade pip wheel

      # CPU-only PyTorch (matches upstream install_deps.sh).
      "$VENV/bin/pip" install \
        torch==2.3.0+cpu torchvision==0.18.0+cpu torchaudio==2.3.0+cpu \
        --index-url https://download.pytorch.org/whl/cpu

      # Project + remaining deps.
      "$VENV/bin/pip" install "$WORK"

      echo "$STAMP" > "$VENV/.mneme-rev"
      echo "[mneme] vault-mcp venv ready."
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    systemd.services."mneme-vault-mcp" = {
      description = "mneme: vault-mcp MCP server";
      wantedBy = [ "multi-user.target" ];
      # vault-mcp uses ChromaDB locally (file-backed under chroma_db).
      # It does not talk to Qdrant; ordering only requires OVMS + network.
      after = [ "network-online.target" "podman-mneme-ovms.service" "mneme-ovms-init.service" ];
      wants = [ "network-online.target" ];

      environment.LD_LIBRARY_PATH = wheelLibPath;
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStartPre = "${bootstrap}/bin/mneme-vault-mcp-bootstrap ${cfg.stateDir}/vault-mcp/venv";
        ExecStart = "${cfg.stateDir}/vault-mcp/venv/bin/vault-mcp --config ${appConfigDir}";
        Restart = "on-failure";
        RestartSec = 5;
        # First-run venv build can take a while.
        TimeoutStartSec = "20min";
        # Hardening (relaxed: bootstrap needs to write under stateDir and reach PyPI).
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.stateDir ];
        ProtectHome = lib.mkDefault "read-only";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}

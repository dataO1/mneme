{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;

  vaultMcpSrc = pkgs.callPackage ../pkgs/vault-mcp.nix { };

  python = pkgs.python311;

  sources =
    (lib.optional (cfg.obsidianVault != null) {
      name = "obsidian";
      type = "obsidian";
      path = toString cfg.obsidianVault;
    })
    ++ (lib.imap0
      (i: dir: {
        name = "files-${toString i}";
        type = "markdown";
        path = toString dir;
      })
      cfg.indexDirectories);

  appToml = pkgs.writeText "vault-mcp-app.toml" ''
    [server]
    host = "127.0.0.1"
    port = ${toString cfg.ports.mcp}

    [embedding_model]
    provider = "openai_endpoint"
    model_name = "embeddings"
    endpoint_url = "http://127.0.0.1:${toString cfg.ports.openvino}/v1"
    api_key = "unused"

    [vector_store]
    provider = "qdrant"
    url = "http://127.0.0.1:${toString cfg.ports.qdrant}"
    collection = "mneme"

    [storage]
    state_dir = "${cfg.stateDir}/vault-mcp"

    [[sources]]
    ${lib.concatMapStringsSep "\n\n[[sources]]\n" (s: ''
      name = "${s.name}"
      type = "${s.type}"
      path = "${s.path}"
    '') sources}
  '';

  # Bootstrap script: idempotently builds a venv at $VENV using upstream's
  # install_deps.sh logic, then installs the project in editable mode.
  # Runs as ExecStartPre. Needs network on first invocation.
  bootstrap = pkgs.writeShellApplication {
    name = "mneme-vault-mcp-bootstrap";
    runtimeInputs = [ python pkgs.gnused pkgs.coreutils ];
    text = ''
      set -euo pipefail
      VENV="$1"
      SRC_RO="${vaultMcpSrc}/share/vault-mcp"
      WORK="${cfg.stateDir}/vault-mcp/build"

      if [ -x "$VENV/bin/vault-mcp" ] && [ -f "$VENV/.mneme-rev" ] \
         && [ "$(cat "$VENV/.mneme-rev")" = "${vaultMcpSrc.version}" ]; then
        exit 0
      fi

      echo "[mneme] First-time setup of vault-mcp venv at $VENV (5–10 min)..."
      rm -rf "$VENV" "$WORK"
      mkdir -p "$WORK"
      cp -rT "$SRC_RO" "$WORK"
      chmod -R u+w "$WORK"

      # mlx-lm is Apple-Silicon-only; remove it before installing.
      sed -i '/^[[:space:]]*"mlx-lm/d' "$WORK/pyproject.toml"

      ${python}/bin/python -m venv "$VENV"
      "$VENV/bin/pip" install --upgrade pip wheel

      # CPU-only PyTorch (matches upstream install_deps.sh).
      "$VENV/bin/pip" install \
        torch==2.3.0+cpu torchvision==0.18.0+cpu torchaudio==2.3.0+cpu \
        --index-url https://download.pytorch.org/whl/cpu

      # Project + remaining deps.
      "$VENV/bin/pip" install "$WORK"

      echo "${vaultMcpSrc.version}" > "$VENV/.mneme-rev"
      echo "[mneme] vault-mcp venv ready."
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    systemd.services."mneme-vault-mcp" = {
      description = "mneme: vault-mcp MCP server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "qdrant.service" "podman-mneme-ovms.service" ];
      requires = [ "qdrant.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStartPre = "${bootstrap}/bin/mneme-vault-mcp-bootstrap ${cfg.stateDir}/vault-mcp/venv";
        ExecStart = "${cfg.stateDir}/vault-mcp/venv/bin/vault-mcp --config ${appToml}";
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

{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;

  vaultMcpPkg = pkgs.callPackage ../pkgs/vault-mcp.nix { };

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
in
{
  config = lib.mkIf cfg.enable {
    systemd.services."mneme-vault-mcp" = {
      description = "mneme: vault-mcp MCP server";
      wantedBy = [ "multi-user.target" ];
      after = [ "qdrant.service" "podman-mneme-ovms.service" ];
      requires = [ "qdrant.service" ];
      environment = {
        VAULT_MCP_CONFIG = appToml;
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${vaultMcpPkg}/bin/vault-mcp --config ${appToml}";
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = "mneme/vault-mcp";
        # Hardening
        ProtectSystem = "strict";
        ProtectHome = lib.mkDefault "read-only";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}

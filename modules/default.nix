{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;
in
{
  imports = [
    (import ./qdrant.nix { inherit self; })
    (import ./openvino.nix { inherit self; })
    (import ./vault-mcp.nix { inherit self; })
  ];

  options.services.mneme = {
    enable = lib.mkEnableOption "mneme — local NPU semantic memory + MCP";

    user = lib.mkOption {
      type = lib.types.str;
      default = "mneme";
      description = "System user that owns mneme state.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "mneme";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/mneme";
      description = "Where Qdrant data, OVMS model cache, and vault-mcp index live.";
    };

    indexDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression ''
        [ "/home/alice/Documents" "/home/alice/Notes" ]
      '';
      description = ''
        Directories to recursively index. The mneme user must have read access.
      '';
    };

    obsidianVault = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional Obsidian vault path (treated as a markdown source with live sync).";
    };

    embeddingModel = lib.mkOption {
      type = lib.types.str;
      default = "BAAI/bge-small-en-v1.5";
      description = "Embedding model served by OpenVINO Model Server on the NPU.";
    };

    ports = {
      qdrant = lib.mkOption {
        type = lib.types.port;
        default = 6333;
      };
      openvino = lib.mkOption {
        type = lib.types.port;
        default = 8000;
      };
      mcp = lib.mkOption {
        type = lib.types.port;
        default = 8765;
        description = "vault-mcp HTTP/SSE port (stdio is also exposed via the CLI wrapper).";
      };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the MCP port in the firewall (default: localhost-only).";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = true;
      # NPU device access (intel_vpu exposes /dev/accel/accel0 via the render group)
      extraGroups = [ "render" "video" ];
    };
    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/qdrant 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/ovms-models 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/vault-mcp 0750 ${cfg.user} ${cfg.group} -"
    ];

    # Ensure the kernel NPU driver is available.
    boot.kernelModules = [ "intel_vpu" ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.ports.mcp ];
  };
}

{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;
in
{
  config = lib.mkIf cfg.enable {
    services.qdrant = {
      enable = true;
      settings = {
        storage = {
          storage_path = "${cfg.stateDir}/qdrant/storage";
          snapshots_path = "${cfg.stateDir}/qdrant/snapshots";
        };
        service = {
          host = "127.0.0.1";
          http_port = cfg.ports.qdrant;
          grpc_port = cfg.ports.qdrant + 1;
        };
        telemetry_disabled = true;
      };
    };

    # Qdrant ships its own user; we just make sure mneme can reach it on localhost.
    # No firewall opening — Qdrant stays bound to 127.0.0.1.
  };
}

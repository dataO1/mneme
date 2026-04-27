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
        # Use Qdrant's default storage paths (/var/lib/qdrant) — its own user
        # owns that tree. Don't repoint into ${cfg.stateDir} or Qdrant fails
        # with Permission denied.
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

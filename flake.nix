{
  description = "mneme — local NPU-accelerated semantic memory exposed over MCP";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      systems = [ "x86_64-linux" ];
    in
    {
      nixosModules.default = import ./modules/default.nix { inherit self; };
      nixosModules.mneme = self.nixosModules.default;
    }
    // flake-utils.lib.eachSystem systems (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages = {
          vault-mcp = pkgs.callPackage ./pkgs/vault-mcp.nix { };
          default = self.packages.${system}.vault-mcp;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ nixpkgs-fmt nil ];
        };
      });
}

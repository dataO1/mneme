{ lib
, stdenv
, fetchFromGitHub
}:

# Source-only derivation. The systemd unit builds a venv on first start using
# this tree as the install target. Pure-Nix packaging is impractical: upstream
# hard-pins torch+cpu from a separate index and pulls mlx-lm (Apple Silicon).
stdenv.mkDerivation rec {
  pname = "vault-mcp-src";
  version = "0.5.0-8838e09a";

  src = fetchFromGitHub {
    owner = "robbiemu";
    repo = "vault-mcp";
    rev = "8838e09ab578819f50541ab8d8c6c77e7deac889";
    hash = "sha256-bOTpRwASJfctZz5YBP/WD6ieVB5T9kYlUSada4vLajs=";
  };

  dontBuild = true;
  dontConfigure = true;
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/share/vault-mcp
    cp -r . $out/share/vault-mcp/
  '';

  meta = with lib; {
    description = "Source tree of robbiemu/vault-mcp (built into a venv at runtime)";
    homepage = "https://github.com/robbiemu/vault-mcp";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}

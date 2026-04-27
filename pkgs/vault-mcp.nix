{ lib
, python3
, fetchFromGitHub
}:

# Best-effort packaging of robbiemu/vault-mcp.
# The upstream uses Poetry; this derivation falls back to a venv-style build
# and is expected to need adjustment after running `nix build` once. The
# downstream NixOS module accepts an override so users can swap this out
# (e.g., for a poetry2nix build) without touching the modules.
python3.pkgs.buildPythonApplication rec {
  pname = "vault-mcp";
  version = "unstable-2026-04-27";
  format = "pyproject";

  src = fetchFromGitHub {
    owner = "robbiemu";
    repo = "vault-mcp";
    rev = "main";
    # TODO: pin a commit and replace with the real hash after the first build.
    hash = lib.fakeHash;
  };

  nativeBuildInputs = with python3.pkgs; [ poetry-core ];

  propagatedBuildInputs = with python3.pkgs; [
    # Common deps for a Python MCP + RAG service. Adjust to match upstream
    # pyproject.toml after first build.
    fastapi
    uvicorn
    httpx
    pydantic
    pydantic-settings
    qdrant-client
    openai
    watchdog
    tomli
    rich
  ];

  doCheck = false;

  meta = with lib; {
    description = "MCP RAG server for Obsidian / Joplin / markdown vaults";
    homepage = "https://github.com/robbiemu/vault-mcp";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}

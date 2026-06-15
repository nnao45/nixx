{ pkgs, lib }:

pkgs.mkShell {
  packages = [
    pkgs.uv
    pkgs.ruff
    pkgs.bun
    pkgs.nodejs
    pkgs.shellcheck
    pkgs.nixpkgs-fmt
    pkgs.statix
    pkgs.nixf
    pkgs.jq
    pkgs.lefthook
  ];
  shellHook = with lib; shellHook {
    hook = bash ''
      # install git hooks (pre-commit: fmt + nix flake check) from lefthook.yml
      lefthook install >/dev/null 2>&1 || true
      echo "nixx dev shell — uv $(uv --version 2>/dev/null), bun $(bun --version 2>/dev/null)"
      echo "run tests:   nix run .#test"
      echo "format:      nix fmt"
      echo "lint/format: nix run .#nix-tasks -- check"
      echo "git hooks:   lefthook (pre-commit → fmt + nix flake check)"
    '';
  };
}

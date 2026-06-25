{ pkgs ? import <nixpkgs> { } }:
let
  nixx = import ../lib.nix;
  writers = import ../writers.nix { inherit pkgs nixx; };
in
with nixx // writers // { inherit pkgs; };
mkTests { name = "math"; packages = [ pkgs.coreutils ]; } {
  "addition via expr" = bash ''
    run expr 2 + 3
    assert_success
    assert_output "5"
  '';
}

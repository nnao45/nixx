# A smoke suite for mkTests, runnable two ways:
#   nix-build tests/example_test.nix            # hermetic (sandbox) lane
#   nix-build tests/example_test.nix -A fast && ./result/bin/smoke-test   # fast lane
{ pkgs ? import <nixpkgs> { } }:
let
  nixx = import ../lib.nix;
  writers = import ../writers.nix { inherit pkgs nixx; };
in
with nixx // writers // { inherit pkgs; };
mkTests { name = "smoke"; packages = [ pkgs.coreutils pkgs.jq ]; } {

  setup = bash ''
    mkdir -p "$WORK/out"
  '';

  "$WORK is writable and isolated" = bash ''
    echo hello > "$WORK/out/greeting.txt"
    assert_file "$WORK/out/greeting.txt"
    assert_file_contains "$WORK/out/greeting.txt" "hello"
  '';

  "run captures status and output" = bash ''
    run printf '%s' "deployed from ${HOME:-nowhere}"
    assert_success
    assert_output --partial "deployed from"
  '';

  "assert_failure catches non-zero" = bash ''
    run false
    assert_failure
  '';

  "assert_json does structural compare" = bash ''
    run jq -n '{ok: true, port: 8080}'
    assert_success
    assert_json '.port' '8080'
    assert_json '.ok' 'true'
  '';
}

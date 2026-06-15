{ mkApps, nixx }:

# Pure-Nix lib tests, evaluated at flake-eval time.
# A failing assertion throws here and prevents the flake from building.
# The resulting script is shellcheck-gated via nixx's own mkApps.
let
  ok = import ../tests/lib-tests.nix;
in
(mkApps { } { test = nixx.sh "echo ${nixx.shq ok}\n"; }).test

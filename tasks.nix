# tasks.nix — pure legal Nix, string-mode bash bodies.
let
  nixx = import ./lib.nix;
  port = 3000;
  message = "it's alive & well";   # quote + ampersand torture
in
nixx.mkTasks { vars = { inherit port message; }; } {

  # showcases: */ glob (impossible in comment-mode), raw $VAR, ''${} rule, @nix
  build = nixx.sh ''
    for d in */; do echo "scanning $d"; done
    sed 's*/*X*' notes.txt || true
    echo "editor=''${EDITOR:-vi} home=$HOME port=@nix(port)"
    greet() { echo "msg: $1"; }
    greet @nix:q(message)
  '';

  # task with deps/env/cwd
  dev = nixx.task {
    deps = [ /usr ];
    env.NODE_ENV = "development";
    cwd = "/tmp";
  } (nixx.sh ''
    echo "NODE_ENV=$NODE_ENV cwd=$(pwd) node=$(command -v node || echo none)"
    echo "would run: npm run dev -- --port @nix(port)"
  '');

  # deliberate shellcheck bug (unquoted $1)
  clean = nixx.sh ''
    target=$1
    rm -rf /tmp/cache/$target
  '';
}

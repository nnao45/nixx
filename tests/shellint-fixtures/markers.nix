with nixx.for pkgs;
{
  deploy = bash ''
    curl @sh:q(url)
    serve --port @nix(port)
    @nix(tool)/bin/run
  '';
}

with nixx.for pkgs;
{
  a = bash ''echo "${HOME}" and ''${LITERAL} at ${pkgs.hello}'';
  b = bash ''echo "''${#ARR[@]}" items'';
}

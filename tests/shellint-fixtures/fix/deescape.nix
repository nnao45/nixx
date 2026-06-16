with nixx.for pkgs;
{
  a = bash ''echo ''${HOME} and ''${EDITOR:-vi} and ''$USER'';
  b = bash ''items=''${#ARR[@]}; path=''${P##*/}; up=''${W^^}'';
  c = bash ''url=${pkgs.hello}/bin'';
}

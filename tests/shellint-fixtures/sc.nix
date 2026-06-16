with nixx.for pkgs;
{
  a = bash ''
    words="a b c"
    echo $words
  '';
}

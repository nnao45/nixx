{
  arr  = nixx.sh ''echo ${ARR[@]}'';
  star = nixx.sh ''echo ${ARR[*]}'';
  len  = nixx.sh ''echo ${#ITEMS}'';
  pre  = nixx.sh ''echo ${PATH#/usr}'';
  base = nixx.sh ''echo ${FILE##*/}'';
  suf  = nixx.sh ''echo ${NAME%.txt}'';
  up   = nixx.sh ''echo ${WORD^^}'';
  down = nixx.sh ''echo ${WORD,,}'';
  neg  = nixx.sh ''echo ${ARR[-1]}'';
  bare = nixx.sh ''echo ${HOME}'';
  keep = nixx.sh ''echo ${pkgs.hello}/bin'';
}

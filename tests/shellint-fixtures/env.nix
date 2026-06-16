with nixx.for pkgs;
{
  job = bash ''
    deploy --key "''${API_KEY:?}" --to "${BUCKET}"
    LOCAL_TMP=hi
    echo "$LOCAL_TMP"
  '';
}

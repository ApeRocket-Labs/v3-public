let
  pkgs = import (builtins.fetchGit rec {
    name = "dapptools-${rev}";
    url = https://github.com/dapphub/dapptools;
    rev = "4471b7ad95c649b41858348e05b491c350a4ca11";
  }) {};

in
  pkgs.mkShell {
    src = null;
    name = "v3";
    buildInputs = with pkgs; [
      pkgs.dapp
    ];
  }

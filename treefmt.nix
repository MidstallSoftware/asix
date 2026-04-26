{ lib, pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    # NOTE: actionlint is broken on Darwin
    actionlint.enable = !pkgs.stdenv.hostPlatform.isDarwin;
    black.enable = true;
    nixfmt.enable = true;
  };
}

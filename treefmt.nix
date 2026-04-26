{ lib, pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    # NOTE: actionlint is broken on Darwin and does not support RISC-V
    actionlint.enable = !pkgs.stdenv.hostPlatform.isDarwin && !pkgs.stdenv.hostPlatform.isRiscV;
    black.enable = true;
    nixfmt.enable = !pkgs.stdenv.hostPlatform.isRiscV;
  };
}

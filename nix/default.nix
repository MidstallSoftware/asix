# asix build infrastructure.
#
# Provides composable builder functions for ASIC tapeout and verification:
#
#   asix.mkTapeout  - ASIC tapeout flow (Yosys + OpenROAD + KLayout)
#   asix.mkVerify   - GDS physical verification (DRC/LVS)
#
# Example usage in a downstream flake:
#
#   {
#     inputs.asix.url = "github:MidstallSoftware/asix";
#     outputs = { self, nixpkgs, asix, ... }:
#       let
#         pkgs = import nixpkgs {
#           system = "x86_64-linux";
#           overlays = [ asix.overlays.default ];
#         };
#       in {
#         packages.x86_64-linux = {
#           my-tapeout = pkgs.asix.mkTapeout {
#             ip = myIp;
#             topCell = "MySoC";
#             pdk = pkgs.gf180mcu-pdk;
#             clockPeriodNs = 20;
#           };
#
#           my-verify = pkgs.asix.mkVerify {
#             tapeout = self.packages.x86_64-linux.my-tapeout;
#           };
#         };
#       };
#   }
{ lib, callPackage }:
{
  mkTapeout = callPackage ./mkTapeout.nix { };
  mkVerify = callPackage ./mkVerify.nix { };
}

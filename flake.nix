{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      nameValuePair = name: value: { inherit name value; };
      genAttrs = names: f: builtins.listToAttrs (map (n: nameValuePair n (f n)) names);
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "riscv64-linux"
      ];

      forAllSystems =
        f:
        genAttrs allSystems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              overlays = [
                self.overlays.default
              ];
            };
          }
        );

      treefmtEval = forAllSystems ({ pkgs, ... }: treefmt-nix.lib.evalModule pkgs (import ./treefmt.nix));
    in
    {
      overlays.default = final: prev: {
        gf180mcu-pdk = final.callPackage ./pkgs/gf180mcu-pdk { };
        sky130-pdk = final.callPackage ./pkgs/sky130-pdk { };
        asix = final.callPackages ./nix { };
      };

      checks = forAllSystems (
        { system, pkgs, ... }:
        {
          formatting = treefmtEval.${system}.config.build.check self;
        }
      );

      packages = forAllSystems (
        { pkgs, ... }:
        {
          inherit (pkgs)
            gf180mcu-pdk
            sky130-pdk
            ;
        }
      );

      formatter = forAllSystems ({ system, ... }: treefmtEval.${system}.config.build.wrapper);

      legacyPackages = forAllSystems ({ pkgs, ... }: pkgs);
    };
}

# asix

Nix flake bundling PDKs, tapeout flows, and verification tooling for silicon.

## PDKs

### GF180MCU

GlobalFoundries 180nm process (gf180mcuD variant via [wafer-space](https://github.com/wafer-space/gf180mcu)). Includes standard cells, tech LEF, GDS, Verilog, SPICE, and KLayout DRC/LVS rule decks. Fab slot definitions and seal ring metadata are exposed through `passthru` for tapeout integration.

### Sky130

SkyWater 130nm process, HD standard cell library (via [google/skywater-pdk](https://github.com/google/skywater-pdk)). Provides LEF, GDS, Verilog, and SPICE. Note that liberty timing generation requires an open_pdks build — this package provides physical views only.

### Overriding PDK configuration

PDK packages accept arguments for key configuration fields:

```nix
gf180mcu-pdk.override {
  cellLib = "gf180mcu_fd_sc_mcu9t5v0";
  siteName = "GF018hv5v_mcu_sc9";
}
```

## Tapeout

`asix.mkTapeout` provides a generic RTL-to-GDS flow using Yosys, OpenROAD, and KLayout. It supports both flat and hierarchical (macro-based) builds.

```nix
my-tapeout = pkgs.asix.mkTapeout {
  ip = myIp;                  # Derivation with RTL + synth/PnR scripts
  topCell = "MySoC";
  pdk = pkgs.gf180mcu-pdk;
  clockPeriodNs = 20;

  # Die dimensions from fab slot
  fabSlot = "1x1";

  # Or explicit dimensions
  # dieWidthUm = 3932;
  # dieHeightUm = 5122;

  # Optional hierarchical hardening
  macros = [ "Core" "Cache" ];
};
```

Intermediate stages (`topSynth`, `topPnr`, `macroDerivations`) are exposed via `passthru`.

## Verification

`asix.mkVerify` runs GDS physical verification — structure checks, fab precheck DRC, detailed DRC, and Verilog-to-SPICE conversion for LVS readiness.

```nix
my-verify = pkgs.asix.mkVerify {
  tapeout = my-tapeout;

  # Optional overrides
  # gatingDrc = false;        # Don't fail on DRC violations
  # enableLvs = false;        # Skip SPICE generation
};
```

## Usage

```nix
{
  inputs.asix.url = "github:MidstallSoftware/asix";
}
```

Use the overlay to pull everything into your nixpkgs:

```nix
nixpkgs.overlays = [ asix.overlays.default ];
```

This gives you `pkgs.gf180mcu-pdk`, `pkgs.sky130-pdk`, and `pkgs.asix.{mkTapeout, mkVerify}`.

## Community

- **Discord**: [Join the server](https://discord.gg/HRhetTVcHG)
- **Contact**: [inquire@midstall.com](mailto:inquire@midstall.com)

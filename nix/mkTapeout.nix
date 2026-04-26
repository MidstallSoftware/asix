# mkTapeout - Generic ASIC tapeout flow: synthesis, PnR, GDS generation.
#
# Supports both flat and hierarchical (macro-based) flows.
# In hierarchical mode, specified modules are hardened as macros
# first, then assembled into the top-level chip.
#
# Usage:
#   asix.mkTapeout {
#     ip = myIp;                  # Derivation with RTL + synthesis/PnR scripts
#     topCell = "MySoC";
#     pdk = gf180mcu-pdk;
#     clockPeriodNs = 20;
#     # Optional hierarchical hardening
#     macros = [ "Core" "Cache" ];
#   }
#
# Outputs:
#   $out/<top>_final.def    - Routed layout (DEF)
#   $out/<top>_final.v      - Post-PnR netlist
#   $out/<top>.gds          - Final GDS
#   $out/macros/            - Per-macro artifacts (LEF, LIB, DEF, GDS)
#   $out/timing.rpt         - Timing report
#   $out/area.rpt           - Area report
#   $out/power.rpt          - Power report
{
  lib,
  stdenv,
  yosys,
  openroad,
  klayout,
}:

lib.extendMkDerivation {
  constructDrv = stdenv.mkDerivation;

  excludeDrvArgNames = [
    "ip"
    "topCell"
    "pdk"
    "cellLib"
    "clockPeriodNs"
    "coreUtilization"
    "macros"
    "macroUtilization"
    "macroHaloUm"
    "fabSlot"
    "dieWidthUm"
    "dieHeightUm"
    "placementDensity"
    "detailedRouteIter"
    "layerAdjustments"
    "analogGdsPaths"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      name ? "asix-tapeout",
      ip,
      topCell ? "top",
      pdk,
      cellLib ? pdk.cellLib or "default",
      clockPeriodNs ? 20,
      coreUtilization ? 0.5,
      macros ? [ ],
      macroUtilization ? 0.6,
      macroHaloUm ? 10,
      fabSlot ? null,
      dieWidthUm ? null,
      dieHeightUm ? null,
      placementDensity ? 0.5,
      detailedRouteIter ? 8,
      layerAdjustments ? pdk.tileLayerAdjustments or { },
      analogGdsPaths ? [ ],
      ...
    }@args:

    assert lib.assertMsg (clockPeriodNs > 0) "mkTapeout: clockPeriodNs must be > 0";
    assert lib.assertMsg (
      coreUtilization > 0.0 && coreUtilization <= 1.0
    ) "mkTapeout: coreUtilization must be in (0, 1]";

    let
      isHierarchical = macros != [ ];

      pdkPath = "${pdk}/${pdk.pdkPath or ""}";
      libsRef = "${pdkPath}/libs.ref/${cellLib}";

      # Resolve die dimensions from fab slot or explicit values
      fab = pdk.fab or { };
      slotDims =
        if fabSlot != null && fab ? slots && fab.slots ? ${fabSlot} then fab.slots.${fabSlot} else null;
      sealRingWidth = if fab ? sealRing then fab.sealRing.width or 0 else 0;
      effectiveDieWidthUm =
        if dieWidthUm != null then
          dieWidthUm
        else if slotDims != null then
          slotDims.w
        else
          null;
      effectiveDieHeightUm =
        if dieHeightUm != null then
          dieHeightUm
        else if slotDims != null then
          slotDims.h
        else
          null;
      # User area is die minus seal ring on each side
      userWidthUm = if effectiveDieWidthUm != null then effectiveDieWidthUm - 2 * sealRingWidth else null;
      userHeightUm =
        if effectiveDieHeightUm != null then effectiveDieHeightUm - 2 * sealRingWidth else null;

      # Generate KLayout LEF/DEF layer map from PDK layer definitions
      lefGdsMapFile = builtins.toFile "lef-gds.map" (
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: val: "${name} ALL ${toString val.layer} ${toString val.datatype}") (
            pdk.lefGdsLayers or { }
          )
        )
      );

      # Build a single macro
      mkMacro =
        macroModule:
        stdenv.mkDerivation {
          name = "asix-macro-${lib.toLower macroModule}-${topCell}";

          dontUnpack = true;
          dontConfigure = true;

          nativeBuildInputs = [
            yosys
            openroad
          ];

          buildPhase = ''
            runHook preBuild

            LIB_FILE=$(find ${libsRef}/lib -name '*tt*' -name '*.lib' -print -quit 2>/dev/null)
            if [ -z "$LIB_FILE" ]; then
              LIB_FILE=$(find ${libsRef}/lib -name '*.lib' -print -quit)
            fi
            TECH_LEF=$(find ${libsRef}/lef -name '*tech*.lef' -o -name '*.tlef' | head -1)

            echo "=== Synthesizing macro: ${macroModule} ==="
            if [ -f "${ip}/macros/${macroModule}_synth.tcl" ]; then
              SV_FILE=$(find ${ip}/rtl -name '*.sv' -print -quit 2>/dev/null || find ${ip} -name '*.sv' -print -quit)
              export SV_FILE LIB_FILE
              yosys -c ${ip}/macros/${macroModule}_synth.tcl 2>&1 | tee yosys.log
            fi

            echo "=== PnR macro: ${macroModule} ==="
            if [ -f "${ip}/macros/${macroModule}_pnr.tcl" ] && [ -f "${macroModule}_synth.v" ]; then
              export LIB_FILE TECH_LEF
              export CELL_LEF_DIR="${libsRef}/lef"
              export SITE_NAME="${pdk.siteName or "unit"}"
              export TILE_UTIL="${toString macroUtilization}"
              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (layer: adj: "export LAYER_ADJ_${layer}=\"${toString adj}\"") layerAdjustments
              )}
              openroad -threads $NIX_BUILD_CORES -exit ${ip}/macros/${macroModule}_pnr.tcl \
                2>&1 | tee openroad.log
            fi

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp ${macroModule}_synth.v $out/ 2>/dev/null || true
            cp ${macroModule}_final.def $out/ 2>/dev/null || true
            cp ${macroModule}.lef $out/ 2>/dev/null || true
            cp ${macroModule}.lib $out/ 2>/dev/null || true
            cp ${macroModule}_timing.rpt $out/ 2>/dev/null || true
            cp ${macroModule}_area.rpt $out/ 2>/dev/null || true
            cp yosys.log $out/ 2>/dev/null || true
            cp openroad.log $out/ 2>/dev/null || true
            runHook postInstall
          '';
        };

      macroDerivations = builtins.listToAttrs (
        map (mod: {
          name = mod;
          value = mkMacro mod;
        }) macros
      );

      # Top-level synthesis
      topSynth = stdenv.mkDerivation {
        name = "asix-top-synth-${topCell}";

        dontUnpack = true;
        dontConfigure = true;

        nativeBuildInputs = [ yosys ];

        buildPhase = ''
          runHook preBuild

          LIB_FILE=$(find ${libsRef}/lib -name '*tt*' -name '*.lib' -print -quit 2>/dev/null)
          if [ -z "$LIB_FILE" ]; then
            LIB_FILE=$(find ${libsRef}/lib -name '*.lib' -print -quit)
          fi

          SV_FILE=$(find ${ip}/rtl -name '*.sv' -print -quit 2>/dev/null || find ${ip} -name '*.sv' -print -quit)
          export SV_FILE LIB_FILE

          ${lib.optionalString isHierarchical ''
            # Provide stubs for blackboxed macros
            export STUBS_V="${ip}/stubs.v"
          ''}

          echo "=== Top-level synthesis ==="
          yosys -c ${ip}/synth.tcl 2>&1 | tee yosys.log

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp ${topCell}_synth.v $out/ 2>/dev/null || true
          cp yosys.log $out/ 2>/dev/null || true
          runHook postInstall
        '';
      };

      # Top-level PnR
      topPnr = stdenv.mkDerivation {
        name = "asix-top-pnr-${topCell}";

        dontUnpack = true;
        dontConfigure = true;

        nativeBuildInputs = [ openroad ];

        buildPhase = ''
          runHook preBuild

          LIB_FILE=$(find ${libsRef}/lib -name '*tt*' -name '*.lib' -print -quit 2>/dev/null)
          if [ -z "$LIB_FILE" ]; then
            LIB_FILE=$(find ${libsRef}/lib -name '*.lib' -print -quit)
          fi
          TECH_LEF=$(find ${libsRef}/lef -name '*tech*.lef' -o -name '*.tlef' | head -1)

          ${lib.optionalString isHierarchical (
            lib.concatMapStringsSep "\n" (mod: ''
              cp ${macroDerivations.${mod}}/${mod}.lef . 2>/dev/null || true
              cp ${macroDerivations.${mod}}/${mod}.lib . 2>/dev/null || true
            '') macros
          )}

          cat > constraints.sdc << EOF
          create_clock [get_ports clk] -name clk -period ${toString clockPeriodNs}
          set_input_delay 0 -clock clk [all_inputs]
          set_output_delay 0 -clock clk [all_outputs]
          EOF

          echo "=== Top-level PnR ==="
          export LIB_FILE TECH_LEF
          export CELL_LEF_DIR="${libsRef}/lef"
          export SYNTH_V="${topSynth}/${topCell}_synth.v"
          export SDC_FILE="constraints.sdc"
          export SITE_NAME="${pdk.siteName or "unit"}"
          export UTILIZATION="${toString coreUtilization}"
          export MACRO_HALO="${toString macroHaloUm}"
          export PLACEMENT_DENSITY="${toString placementDensity}"
          export DROUTE_END_ITER="${toString detailedRouteIter}"
          ${lib.optionalString (userWidthUm != null && userHeightUm != null) ''
            export DIE_AREA="0 0 ${toString userWidthUm} ${toString userHeightUm}"
          ''}
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (layer: adj: "export LAYER_ADJ_${layer}=\"${toString adj}\"") layerAdjustments
          )}

          openroad -threads $NIX_BUILD_CORES -exit ${ip}/pnr.tcl \
            2>&1 | tee openroad.log

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp ${topCell}_final.def $out/ 2>/dev/null || true
          cp ${topCell}_final.v $out/ 2>/dev/null || true
          cp timing.rpt $out/ 2>/dev/null || true
          cp area.rpt $out/ 2>/dev/null || true
          cp power.rpt $out/ 2>/dev/null || true
          cp openroad.log $out/ 2>/dev/null || true
          runHook postInstall
        '';
      };
    in
    builtins.removeAttrs args [
      "ip"
      "topCell"
      "pdk"
      "cellLib"
      "clockPeriodNs"
      "coreUtilization"
      "macros"
      "macroUtilization"
      "macroHaloUm"
      "fabSlot"
      "dieWidthUm"
      "dieHeightUm"
      "placementDensity"
      "detailedRouteIter"
      "layerAdjustments"
      "analogGdsPaths"
    ]
    // {
      dontUnpack = true;
      dontConfigure = true;

      nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
        klayout
      ];

      buildPhase = ''
        runHook preBuild

        if [ -f "${topPnr}/${topCell}_final.def" ]; then
          echo "=== DEF to GDS ==="

          ${lib.optionalString isHierarchical ''
            mkdir -p macro_gds macro_lef
            ${lib.concatMapStringsSep "\n" (mod: ''
              cp ${macroDerivations.${mod}}/${mod}_final.gds macro_gds/ 2>/dev/null || true
              cp ${macroDerivations.${mod}}/${mod}.lef macro_lef/ 2>/dev/null || true
            '') macros}
          ''}

          TECH_LEF=$(find ${libsRef}/lef -name '*tech*.lef' -o -name '*.tlef' | head -1)

          CELL_GDS_DIR="${libsRef}/gds" \
          ${lib.optionalString isHierarchical ''MACRO_GDS_DIR="macro_gds"''} \
          ${lib.optionalString isHierarchical ''MACRO_LEF_DIR="macro_lef"''} \
          LEF_DIR="${libsRef}/lef" \
          TECH_LEF="$TECH_LEF" \
          DEF_FILE="${topPnr}/${topCell}_final.def" \
          OUT_GDS="${topCell}.gds" \
          LAYER_MAP="${lefGdsMapFile}" \
          QT_QPA_PLATFORM=offscreen \
          klayout -b -r ${./scripts/def2gds.py} \
            2>&1 | tee klayout.log || true

          if [ -f "${topCell}.gds" ]; then
            echo "=== Stamp Nix store path ==="

            GDS_FILE="${topCell}.gds" \
            STAMP_TEXT="$out" \
            LAYER="${toString (pdk.commentLayer.layer or 236)}" \
            DATATYPE="${toString (pdk.commentLayer.datatype or 0)}" \
            QT_QPA_PLATFORM=offscreen \
            klayout -b -r ${./scripts/stamp_text.py} \
              2>&1 | tee -a klayout.log

            ${lib.optionalString (effectiveDieWidthUm != null && effectiveDieHeightUm != null) ''
              echo "=== Fab finalize ==="

              GDS_FILE="${topCell}.gds" \
              TOP_CELL="${topCell}" \
              DIE_W_UM="${toString effectiveDieWidthUm}" \
              DIE_H_UM="${toString effectiveDieHeightUm}" \
              ${lib.optionalString (fab ? sealRing) ''SEAL_LAYER="${toString fab.sealRing.layer}"''} \
              ${lib.optionalString (fab ? sealRing) ''SEAL_DATATYPE="${toString fab.sealRing.datatype}"''} \
              ${lib.optionalString (fab ? sealRing) ''SEAL_WIDTH_UM="${toString fab.sealRing.width}"''} \
              ${lib.optionalString (fab ? idCell) ''ID_CELL="${fab.idCell}"''} \
              QT_QPA_PLATFORM=offscreen \
              klayout -b -r ${./scripts/fab_finalize.py} \
                2>&1 | tee -a klayout.log
            ''}

            ${lib.optionalString (analogGdsPaths != [ ]) ''
              echo "=== Merge analog GDS ==="
              if [ -f "${ip}/klayout/gds_merge.py" ]; then
                QT_QPA_PLATFORM=offscreen \
                klayout -b -r ${ip}/klayout/gds_merge.py 2>&1 | tee -a klayout.log || true
              fi
            ''}

            echo "=== DRC ==="
            if [ -f "${ip}/klayout/drc.py" ]; then
              QT_QPA_PLATFORM=offscreen \
              klayout -b -r ${ip}/klayout/drc.py 2>&1 | tee -a klayout.log || true
            fi
          fi
        fi

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out

        # Macro artifacts
        ${lib.optionalString isHierarchical ''
          mkdir -p $out/macros
          ${lib.concatMapStringsSep "\n" (mod: ''
            cp -r ${macroDerivations.${mod}}/* $out/macros/ 2>/dev/null || true
          '') macros}
        ''}

        # Top-level synthesis
        cp ${topSynth}/${topCell}_synth.v $out/ 2>/dev/null || true
        cp ${topSynth}/yosys.log $out/yosys.log 2>/dev/null || true

        # Top-level PnR
        cp ${topPnr}/${topCell}_final.def $out/ 2>/dev/null || true
        cp ${topPnr}/${topCell}_final.v $out/ 2>/dev/null || true
        cp ${topPnr}/timing.rpt $out/ 2>/dev/null || true
        cp ${topPnr}/area.rpt $out/ 2>/dev/null || true
        cp ${topPnr}/power.rpt $out/ 2>/dev/null || true
        cp ${topPnr}/openroad.log $out/ 2>/dev/null || true

        # GDS + verification
        cp ${topCell}.gds $out/ 2>/dev/null || true
        cp ${topCell}_drc.xml $out/ 2>/dev/null || true
        cp klayout.log $out/ 2>/dev/null || true

        runHook postInstall
      '';

      passthru = {
        inherit
          ip
          pdk
          cellLib
          topCell
          clockPeriodNs
          coreUtilization
          topSynth
          topPnr
          ;
        inherit (finalAttrs) name;
      }
      // lib.optionalAttrs isHierarchical {
        inherit macroDerivations;
      }
      // (args.passthru or { });
    };
}

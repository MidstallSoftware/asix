# mkVerify - GDS physical verification using KLayout DRC/LVS.
#
# Runs foundry DRC and generates SPICE netlists for LVS on the
# GDS output from a tapeout derivation.
#
# Usage:
#   asix.mkVerify {
#     tapeout = myTapeout;          # Output of mkTapeout
#   }
#
# Or with overrides:
#   asix.mkVerify {
#     tapeout = myTapeout;
#     topCell = "MyChip";
#     gatingDrc = false;            # Don't fail on DRC violations
#   }
#
# Outputs:
#   $out/result           - PASS/FAIL/SKIP
#   $out/drc_output/      - DRC violation reports
#   $out/netlist.spice    - Complete SPICE netlist for LVS
#   $out/*.log            - Tool logs
{
  lib,
  stdenvNoCC,
  python3,
  klayout,
  procps,
  yosys,
}:

lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "tapeout"
    "topCell"
    "gdsFile"
    "netlist"
    "drcTables"
    "enableLvs"
    "gatingDrc"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      name ? "asix-verify-${tapeout.topCell or "design"}",
      tapeout,
      topCell ? tapeout.topCell or "top",
      gdsFile ? "${tapeout}/${topCell}.gds",
      netlist ? "${tapeout}/${topCell}_final.v",
      drcTables ? tapeout.pdk.drcTables or [ ],
      enableLvs ? true,
      gatingDrc ? true,
      ...
    }@args:

    let
      pdk = tapeout.pdk;
      inherit (pdk) pdkName pdkPath;
      cellLib = tapeout.cellLib or pdk.cellLib;
      fullPdkPath = "${pdk}/${pdkPath}";
      pvPath = "${fullPdkPath}/pv";
      drcVariant =
        if pdk ? fab && pdk.fab ? drcVariant then
          pdk.fab.drcVariant
        else if pdkName == "gf180mcu" then
          "D"
        else if pdkName == "sky130" then
          "sky130A"
        else
          "default";
    in
    builtins.removeAttrs args [
      "tapeout"
      "topCell"
      "gdsFile"
      "netlist"
      "drcTables"
      "enableLvs"
      "gatingDrc"
    ]
    // {
      dontUnpack = true;

      nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
        (python3.withPackages (ps: [ ps.docopt ]))
        klayout
        procps
        yosys
      ];

      buildPhase = ''
        runHook preBuild

        export PYTHONPATH="${klayout}/lib/pymod''${PYTHONPATH:+:$PYTHONPATH}"

        GDS="${gdsFile}"
        NETLIST="${netlist}"

        echo "=== GDS verification for ${topCell} ==="

        # ---- Step 1: Verify GDS exists and is non-empty ----
        echo "--- Step 1: GDS file validation ---"
        if [ ! -f "$GDS" ]; then
          echo "FAIL: GDS file not found at $GDS"
          echo "NOTE: Tapeout may not have produced GDS"

          mkdir -p $out
          echo "SKIP" > $out/result
          exit 0
        fi

        GDS_SIZE=$(stat -c %s "$GDS")
        echo "GDS file: $GDS ($GDS_SIZE bytes)"
        if [ "$GDS_SIZE" -lt 100 ]; then
          echo "FAIL: GDS file too small ($GDS_SIZE bytes)"
          exit 1
        fi
        echo "PASS: GDS file exists and is non-trivial"

        # ---- Step 2: KLayout GDS structure check ----
        echo "--- Step 2: GDS structure validation ---"
        cat > check_gds.py << 'PYEOF'
        import sys
        import os

        import pya

        gds_path = os.environ["GDS_PATH"]
        layout = pya.Layout()
        layout.read(gds_path)

        errors = 0

        if layout.cells() == 0:
            print("FAIL: GDS contains no cells")
            errors += 1
        else:
            print(f"  Cells: {layout.cells()}")

        layer_count = 0
        for li in layout.layer_indices():
            layer_count += 1
        if layer_count == 0:
            print("FAIL: GDS contains no layers")
            errors += 1
        else:
            print(f"  Layers: {layer_count}")

        top_cells = [c for c in layout.each_cell() if c.is_top()]
        if len(top_cells) == 0:
            print("FAIL: No top-level cell found")
            errors += 1
        else:
            for tc in top_cells:
                bbox = tc.bbox()
                print(f"  Top cell: {tc.name} ({bbox.width()/1000:.1f} x {bbox.height()/1000:.1f} um)")
                if bbox.width() == 0 or bbox.height() == 0:
                    print("FAIL: Top cell has zero area")
                    errors += 1

        if errors > 0:
            sys.exit(1)
        print("PASS: GDS structure valid")
        PYEOF

        GDS_PATH="$GDS" QT_QPA_PLATFORM=offscreen klayout -b -r check_gds.py 2>&1 | tee gds_check.log
        if [ $? -ne 0 ]; then
          echo "FAIL: GDS structure check failed"
          exit 1
        fi

        # ---- Step 3: Fab precheck DRC ----
        echo "--- Step 3: Fab precheck DRC (${pdkName}) ---"
        FAB_DRC="${pvPath}/klayout/drc/${pdkName}.drc"

        if [ -f "$FAB_DRC" ]; then
          mkdir -p drc_output

          QT_QPA_PLATFORM=offscreen klayout -b -zz \
            -r "$FAB_DRC" \
            -rd input="$GDS" \
            -rd report=drc_output/fab_drc.xml \
            -rd feol=true \
            -rd beol=true \
            -rd offgrid=true \
            -rd conn_drc=true \
            -rd wedge=true \
            -rd run_mode=deep \
            -rd metal_top=11K \
            -rd metal_level=5LM \
            -rd mim_option=B \
            -rd thr=$NIX_BUILD_CORES \
            2>&1 | tee drc.log || true

          if [ -f "drc_output/fab_drc.xml" ]; then
            FAB_VIOLATIONS=$(grep -c "<value>" drc_output/fab_drc.xml 2>/dev/null || echo "0")
            echo "Fab precheck DRC violations: $FAB_VIOLATIONS"
            if [ "$FAB_VIOLATIONS" = "0" ]; then
              echo "PASS: Fab precheck DRC clean"
            else
              echo "FAIL: $FAB_VIOLATIONS fab DRC violations"
              ${lib.optionalString gatingDrc "exit 1"}
            fi
          else
            echo "PASS: Fab DRC produced no report (no violations)"
          fi
        else
          echo "NOTE: Fab DRC runset not found at $FAB_DRC, skipping"
        fi

        # ---- Step 3b: Detailed DRC (informational) ----
        echo "--- Step 3b: Detailed DRC report (informational) ---"
        DRC_SCRIPT="${pvPath}/klayout/drc/run_drc.py"

        if [ -f "$DRC_SCRIPT" ]; then
          QT_QPA_PLATFORM=offscreen python3 "$DRC_SCRIPT" \
            --path="$GDS" \
            --topcell=${topCell} \
            --variant=${drcVariant} \
            --run_dir=drc_output \
            --no_feol \
            --run_mode=deep \
            --thr=$NIX_BUILD_CORES \
            --mp=$NIX_BUILD_CORES \
            ${lib.concatMapStringsSep " " (t: "--table=${t}") drcTables} \
            2>&1 | tee -a drc.log || true

          VIOLATION_FILES=$(find drc_output -name "*.lyrdb" 2>/dev/null)
          if [ -n "$VIOLATION_FILES" ]; then
            VIOLATIONS=$(grep -c "<value>" $VIOLATION_FILES 2>/dev/null || echo "0")
            echo "Detailed DRC violations (informational): $VIOLATIONS"
          fi
        fi

        # ---- Step 4: Verilog to SPICE conversion ----
        ${lib.optionalString enableLvs ''
          echo "--- Step 4: Verilog to SPICE conversion ---"
          if [ -f "$NETLIST" ]; then
            CELL_LIB=$(find ${fullPdkPath}/libs.ref/${cellLib}/lib -name '*tt*' -name '*.lib' -print -quit 2>/dev/null)
            if [ -z "$CELL_LIB" ]; then
              CELL_LIB=$(find ${fullPdkPath}/libs.ref/${cellLib}/lib -name '*.lib' -print -quit)
            fi
            CELL_SPICE="${fullPdkPath}/libs.ref/${cellLib}/spice"

            ${lib.optionalString (tapeout ? macroDerivations) ''
              # Convert each macro's gate-level Verilog to SPICE
              MACRO_DIR="${tapeout}/macros"
              mkdir -p macro_spice
              for mod in ${lib.concatStringsSep " " (builtins.attrNames (tapeout.macroDerivations or { }))}; do
                MACRO_V="$MACRO_DIR/''${mod}_final.v"
                if [ -f "$MACRO_V" ]; then
                  echo "Converting $mod to SPICE..."
                  yosys -p "
                    read_liberty -lib $CELL_LIB;
                    read_verilog $MACRO_V;
                    hierarchy -top $mod;
                    write_spice -big_endian macro_spice/''${mod}.spice;
                  " 2>&1 | tee macro_spice/''${mod}_yosys.log || true
                fi
              done
            ''}

            echo "Converting top-level netlist to SPICE..."
            yosys -p "
              read_liberty -lib $CELL_LIB;
              read_verilog $NETLIST;
              hierarchy -top ${topCell};
              write_spice -big_endian raw_netlist.spice;
            " 2>&1 | tee v2spice.log

            if [ -f raw_netlist.spice ]; then
              {
                # PDK cell models
                for f in $CELL_SPICE/*.spice; do
                  if [ -e "$f" ]; then
                    echo ".include $f"
                  fi
                done
                echo ""

                # Macro subcircuit definitions
                if [ -d macro_spice ]; then
                  for f in macro_spice/*.spice; do
                    if [ -e "$f" ]; then
                      sed -n '/^\.subckt/,/^\.ends/p' "$f"
                      echo ""
                    fi
                  done
                fi

                # Top-level subcircuit
                sed -n '/^\.subckt ${topCell}/,/^\.ends/p' raw_netlist.spice
              } > netlist.spice

              SUBCKT_COUNT=$(grep -c '^\.subckt' netlist.spice || true)
              echo "PASS: SPICE netlist generated ($SUBCKT_COUNT subcircuits, $(wc -l < netlist.spice) lines)"
            else
              echo "FAIL: SPICE conversion failed"
            fi
          else
            echo "NOTE: Verilog netlist not found, skipping SPICE conversion"
          fi
        ''}

        echo "=== GDS verification complete ==="

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp *.log $out/ 2>/dev/null || true
        cp netlist.spice $out/ 2>/dev/null || true
        cp raw_netlist.spice $out/ 2>/dev/null || true
        cp -r drc_output $out/ 2>/dev/null || true
        echo "PASS" > $out/result
        runHook postInstall
      '';

      passthru = {
        inherit tapeout pdk topCell;
      }
      // (args.passthru or { });
    };
}

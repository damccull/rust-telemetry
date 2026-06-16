{
  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-unstable";
    };
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    surrealdb-gh.url = "github:surrealdb/surrealdb/v2.3.6";
    dioxus-cli-gh.url = "github:DioxusLabs/dioxus";
  };
  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import inputs.rust-overlay) ];
          config = {
            allowUnfreePredicate =
              pkg:
              builtins.elem (lib.getName pkg) ([
              ]);
          };
        };

        lib = nixpkgs.lib;

        runtimeDeps = with pkgs; [
        ];

        buildDeps = with pkgs; [
          # llvmPackages_21.clang-unwrapped
          pkg-config
          rustPlatform.bindgenHook
        ];

        devDeps = with pkgs; [
          # Libraries and programs needed for dev work; included in dev shell
          # NOT included in the nix build operation
          bacon
          bunyan-rs
          cargo-deny
          cargo-edit
          cargo-expand
          cargo-msrv
          cargo-nextest
          cargo-watch
          (cargo-whatfeatures.overrideAttrs (oldAttrs: rec {
            version = "0.9.13";
            src = fetchCrate {
              pname = "cargo-whatfeatures";
              version = "${version}";
              hash = "sha256-Nbyr7u47c6nImzYJvPVLfbqgDvzyXqR1C1tOLximuHU=";
            };

            cargoDeps = rustPlatform.fetchCargoVendor {
              inherit src;
              inherit (src) pname version;
              hash = "sha256-p95aYXsZM9xwP/OHEFwq4vRiXoO1n1M0X3TNbleH+Zw=";
            };
          }))
          fish
          gdb
          just
          nushell
          openssl
          panamax
          tailwindcss
          zellij
        ];

        cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
        msrv = cargoToml.package.rust-version;

        rustPackage =
          features:
          (pkgs.makeRustPlatform {
            cargo = pkgs.rust-bin.stable.latest.minimal;
            rustc = pkgs.rust-bin.stable.latest.minimal;
          }).buildRustPackage
            {
              inherit (cargoToml.package) name version;
              # Clean the source to avoid blatant target/ blob copying
              src = pkgs.lib.cleanSource ./.;
              cargoLock.lockFile = ./Cargo.lock;
              buildFeatures = features;
              buildInputs = runtimeDeps;
              nativeBuildInputs = buildDeps;
              # Uncomment if your cargo tests require networking or otherwise
              # don't play nicely with the nix build sandbox:
              # doCheck = false;
            };

        ldpath = with pkgs; [
        ];

        mkDevShell =
          rustc:
          pkgs.mkShell.override { stdenv = pkgs.clangStdenv; } {
            shellHook = ''
              export SHELL="${pkgs.fish}/bin/fish"

              # 1. [[ $- == *i* ]] checks if the CURRENT execution shell context is interactive.
              # 2. [ -z "$i" ] guards against some edge-case nested script evaluation loops.
              if [[ $- == *i* ]] && [ -z "$i" ]; then
                export i=1
                exec $SHELL -i
              fi
            '';
            LD_LIBRARY_PATH = lib.makeLibraryPath ldpath;

            # Override gcc with clang. Must use unwrapped version because the wrapper does not
            # allow passing a target as an argument, breaking wasm compiles
            CC = "${pkgs.llvmPackages_21.clang-unwrapped}/bin/clang";
            CXX = "${pkgs.llvmPackages_21.clang-unwrapped}/bin/clang++";

            GIO_MODULE_DIR = "${pkgs.glib-networking}/lib/gio/modules/";

            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
            buildInputs = runtimeDeps;
            nativeBuildInputs = buildDeps ++ devDeps ++ [ rustc ];
          };

        rustTargets = [
          "x86_64-unknown-linux-gnu"
          "x86_64-linux-android"
          "aarch64-linux-android"
          "wasm32-unknown-unknown"
        ];

        rustExtensions = [
          "rust-analyzer"
          "rust-src"
        ];

        buildWorkspaceMember =
          {
            name,
            subdir,
            features ? [ ],
          }:
          (pkgs.makeRustPlatform {
            cargo = pkgs.rust-bin.stable.latest.minimal;
            rustc = pkgs.rust-bin.stable.latest.minimal;
          }).buildRustPackage
            {
              pname = name;
              version = "0.1.0";

              src = pkgs.lib.cleanSource ./.;
              cargoLock.lockFile = ./Cargo.lock;

              buildAndTestSubdir = subdir;
              buildFeatures = features;
              buildInputs = runtimeDeps;
              nativeBuildInputs = buildDeps;
            };

        buildWholeWorkspace =
          {
            name,
            features ? [ ],
          }:
          (pkgs.makeRustPlatform {
            cargo = pkgs.rust-bin.stable.latest.minimal;
            rustc = pkgs.rust-bin.stable.latest.minimal;
          }).buildRustPackage
            {
              pname = name;
              version = "0.1.0";

              src = pkgs.lib.cleanSource ./.;
              cargoLock.lockFile = ./Cargo.lock;

              buildFeatures = features;
              buildInputs = runtimeDeps;
              nativeBuildInputs = buildDeps;
            };
      in
      rec {

        packages.default = packages.workspace;
        packages.workspace = buildWholeWorkspace {
          name = "rust-sandbox-complete";
        };
        packages.encrypted_log_custom_pack = buildWorkspaceMember {
          name = "enrypted_log_custom_pack";
          subdir = "encrypted_log_custom_pack";
          features = [ ];
        };
        packages.hello_world = buildWorkspaceMember {
          name = "hello_world";
          subdir = "hello_world";
          features = [ ];
        };

        devShells.default = devShells.stable;
        devShells.nightly = (
          mkDevShell (
            pkgs.rust-bin.selectLatestNightlyWith (
              toolchain:
              toolchain.default.override {
                extensions = rustExtensions;
                targets = rustTargets;
              }
            )
          )
        );
        devShells.stable = (
          mkDevShell (
            pkgs.rust-bin.stable.latest.default.override {
              extensions = rustExtensions;
              targets = rustTargets;
            }
          )
        );
        devShells.msrv = (
          mkDevShell (
            pkgs.rust-bin.stable.${msrv}.default.override {
              extensions = rustExtensions;
              targets = rustTargets;
            }
          )
        );
      }
    );
}

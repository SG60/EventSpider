{
  description = "A very basic flake";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, fenix, crane }:

    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        craneLib = crane.lib.${system}.overrideToolchain
          fenix.packages.${system}.stable.minimalToolchain;

        src = lib.cleanSourceWith {
          src = craneLib.path ./.;
          filter = combinedCraneSourceFilter;
        };
        inherit (pkgs) lib;

        nixTargetsToRust = {
          aarch64-linux = "aarch64-unknown-linux-gnu";
          x86_64-linux = "x86_64-unknown-linux-gnu";
        };
        nixTargetsToDockerArch = { aarch64-linux = "arm64"; x86_64-linux = "amd64"; };
        # cross-target-systems = with flake-utils.lib.system; [ aarch64-linux x86_64-linux ];
        crossTargetSystems = with flake-utils.lib.system; { "aarch64-linux" = { nixTarget = aarch64-linux; }; "x86_64-linux" = { nixTarget = x86_64-linux; }; };
        # TODO: Can this be merged with the normal compilation (do them all in one set of stuff, to avoid repeating myself?)
        cross-results = builtins.mapAttrs
          (name: targetAttrsValue:
            let
              targetSystem = targetAttrsValue.nixTarget;

              dashesToUnderscores = builtins.replaceStrings [ "-" ] [ "_" ];
              toUnderscoresAndCapitals = x: lib.strings.toUpper (dashesToUnderscores x);

              qemu-command = "qemu-" + builtins.head (lib.strings.splitString "-" targetSystem);
              rust-target = nixTargetsToRust.${targetSystem};
              rustTargetForEnvVars = toUnderscoresAndCapitals rust-target;

              nix-cross-pkgs = import nixpkgs { localSystem = system; crossSystem = targetSystem; };

              toolchain = with fenix.packages.${system}; combine
                [ stable.minimalToolchain targets.${rust-target}.stable.rust-std ];
              craneLib = crane.lib.${system}.overrideToolchain toolchain;

              extra_env_when_cross_targets = lib.attrsets.optionalAttrs (targetSystem != system) {
                "CARGO_TARGET_${rustTargetForEnvVars}_RUNNER" = qemu-command;
              };
              # Common arguments can be set here to avoid repeating them later
              cross-common-args = {
                strictDeps = true;

                # whether to run check phase (cargo test)
                doCheck = false;

                inherit src;
                CARGO_BUILD_TARGET = rust-target;

                # Tell cargo about the linker and an optional emulater. So they can be used in `cargo build`
                # and `cargo run`.
                # Environment variables are in format `CARGO_TARGET_<UPPERCASE_UNDERSCORE_RUST_TRIPLE>_LINKER`.
                # They are also be set in `.cargo/config.toml` instead.
                # See: https://doc.rust-lang.org/cargo/reference/config.html#target
                "CARGO_TARGET_${rustTargetForEnvVars}_LINKER" = "${nix-cross-pkgs.stdenv.cc.targetPrefix}gcc";
                # "CARGO_TARGET_${rustTargetForEnv}_RUNNER" = qemu-command;

                # Dependencies which need to be build for the current platform
                # on which we are doing the cross compilation. In this case,
                # pkg-config needs to run on the build platform so that the build
                # script can find the location of openssl. Note that we don't
                # need to specify the rustToolchain here since it was already
                # overridden above.
                nativeBuildInputs = with nix-cross-pkgs; (with pkgsBuildHost; [ protobuf ]) ++ [ stdenv.cc ];

                # Build-time tools which are target agnostic. build = host = target = your-machine.
                # Emulators should essentially also go `nativeBuildInputs`. But with some packaging issue,
                # currently it would cause some rebuild.
                # We put them here just for a workaround.
                # See: https://github.com/NixOS/nixpkgs/pull/146583
                depsBuildBuild = with nix-cross-pkgs; if targetSystem != system then [ pkgsBuildBuild.qemu ] else [ ];

                # Dependencies which need to be built for the platform on which
                # the binary will run. In this case, we need to compile openssl
                # so that it can be linked with our executable.
                # buildInputs = [];

                # This environment variable may be necessary if any of your dependencies use a
                # build-script which invokes the `cc` crate to build some other code. The `cc` crate
                # should automatically pick up on our target-specific linker above, but this may be
                # necessary if the build script needs to compile and run some extra code on the build
                # system.
                # HOST_CC = "${nix-cross-pkgs.stdenv.cc.nativePrefix}cc";
                TARGET_CC = "${nix-cross-pkgs.stdenv.cc.targetPrefix}cc";
              } // extra_env_when_cross_targets;

              # Build *just* the cargo dependencies, so we can reuse
              # all of that work (e.g. via cachix) when running in CI
              cargoArtifacts = craneLib.buildDepsOnly cross-common-args;
              # Build the actual crate itself, reusing the dependency
              # artifacts from above.
              hello-rust = craneLib.buildPackage (cross-common-args // {
                inherit cargoArtifacts;
                # Don't build any other binary artifacts!
                # cargoExtraArgs = "--bin=hello-rust-backend";

                # useful site: https://jade.fyi/blog/optimizing-nix-docker/
                postInstall = with nix-cross-pkgs; ''
                  ${removeReferencesTo}/bin/remove-references-to -t ${stdenv.cc.cc} $out/bin/hello-rust-backend
                '';
                # This attribute is similar to disallowedReferences, but it specifies illegal requisites for
                # the whole closure, so all the dependencies recursively.
                disallowedRequisites = with nix-cross-pkgs; [ stdenv.cc.cc ];
              });
              docker = pkgs.dockerTools.streamLayeredImage {
                name = "hello-rust-backend";
                tag = "nix-latest-build-tag";
                architecture = nixTargetsToDockerArch.${targetSystem};
                contents = [ hello-rust pkgs.cacert ];
                config = {
                  Entrypoint = [ "${hello-rust}/bin/hello-rust-backend" ];
                };
              };
            in
            lib.attrsets.recurseIntoAttrs
              {
                inherit targetSystem docker;
                bin = hello-rust;
                app = flake-utils.lib.mkApp {
                  drv = nix-cross-pkgs.writeScriptBin "hello-rust-backend" ''
                    ${lib.strings.optionalString (system != targetSystem) "${pkgs.pkgsBuildBuild.qemu}/bin/${qemu-command} "}${hello-rust}/bin/hello-rust-backend
                  '';
                };

                buildShell = craneLib.devShell (cross-common-args // {
                  # Automatically inherit any build inputs from `my-crate`
                  inputsFrom = [ hello-rust ];
                  # Extra inputs (only used for interactive development)
                  # can be added here; cargo and rustc are provided by default.
                  packages = [ fenix.packages.${system}.stable.clippy pkgs.just ];
                });

                # Install only the dependencies into a docker image.
                # This requires adding the dependencies manually.
                dockerDependenciesOnly = pkgs.dockerTools.streamLayeredImage {
                  name = "hello-rust-backend-dependencies";
                  tag = "nix-latest-build-tag";
                  architecture = nixTargetsToDockerArch.${targetSystem};
                  contents = [ nix-cross-pkgs.stdenv.cc.libc pkgs.cacert ];
                };

                # Run clippy (and deny all warnings) on the crate source,
                # reusing the dependency artifacts (e.g. from build scripts or
                # proc-macros) from above.
                #
                # Note that this is done as a separate derivation so it
                # does not impact building just the crate by itself.
                hello-rust-clippy = craneLib.cargoClippy (cross-common-args // {
                  # Again we apply some extra arguments only to this derivation
                  # and not every where else. In this case we add some clippy flags
                  inherit cargoArtifacts;
                });

                hello-rust-test = craneLib.cargoTest (cross-common-args // {
                  inherit cargoArtifacts;
                });
              }
          )
          crossTargetSystems;

        flattenOneLevel = with lib.attrsets; concatMapAttrs (name: value: mapAttrs' (name2: value2: nameValuePair ("${name2}/${name}") value2) value);
        filterFlattenedByPrefixes = with lib.attrsets // lib.strings;  prefixes: attrset: filterAttrs (name: v: builtins.foldl' (a: b: a || hasPrefix b name) false prefixes) attrset;

        cross-flattened = flattenOneLevel cross-results;
        crossPackages = filterFlattenedByPrefixes [ "docker/" "bin/" "dockerDependenciesOnly/" ] cross-flattened;
        crossApps = filterFlattenedByPrefixes [ "app/" ] cross-flattened;
        crossBuildShells = filterFlattenedByPrefixes [ "buildShell/" ] cross-flattened;

        hello-rust-clippy = cross-flattened."hello-rust-clippy/${system}";
        hello-rust-test = cross-flattened."hello-rust-test/${system}";

        # keep proto files
        protoFilter = path: _type: builtins.match ".*proto$" path != null;
        # combine with the default source filter
        combinedCraneSourceFilter = path: type:
          (protoFilter path type) || (craneLib.filterCargoSources path type);
      in
      {
        packages = { default = crossPackages."bin/${system}"; } // crossPackages;
        devShells = {
          default = with pkgs; mkShell {
            nativeBuildInputs = [ pkgsBuildHost.protobuf ];
          };
          k8s = pkgs.mkShell { buildInputs = with pkgs; [ skaffold ]; };
        } // crossBuildShells;

        apps = crossApps;

        checks = {
          inherit hello-rust-clippy hello-rust-test;
        };

        formatter = nixpkgs.legacyPackages.${system}.nixpkgs-fmt;
      });
}

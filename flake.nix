{
  description = "spirits - NixOS VMs on Apple Silicon via Virtualization.framework";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      darwinSystem = "aarch64-darwin";
      hostPkgs = nixpkgs.legacyPackages.${darwinSystem};

      run-spirit = hostPkgs.stdenv.mkDerivation {
        pname = "run-spirit";
        version = "0.1.0";
        src = ./swift;

        nativeBuildInputs = with hostPkgs; [
          swift
          swiftpm
          swiftPackages.Foundation
          darwin.sigtool
        ];

        buildPhase = ''
          export HOME=$(mktemp -d)
          swift build -c release --scratch-path .build
        '';

        dontStrip = true;

        installPhase = ''
          mkdir -p $out/bin
          cp .build/release/run-spirit $out/bin/run-spirit
          codesign --force --entitlements Entitlements.plist -s - $out/bin/run-spirit
        '';
      };

      spiritBin = "${run-spirit}/bin/run-spirit";
    in
    {
      nixosModules.default = {
        imports = [
          ./modules/nixos/guest.nix
          ./modules/nixos/virtio-fs.nix
        ];
      };

      darwinModules.default = import ./modules/darwin/vms.nix { inherit spiritBin; };
    };
}

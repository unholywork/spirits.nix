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

      testSSHKey =
        hostPkgs.runCommand "test-ssh-key"
          {
            nativeBuildInputs = [ hostPkgs.openssh ];
          }
          ''
            mkdir -p $out
            ssh-keygen -t ed25519 -f $out/id_ed25519 -N "" -q
          '';

      testVM = import ./tests/test-vm.nix {
        inherit nixpkgs;
        spiritsModule = self.nixosModules.default;
        sshPubKey = builtins.readFile "${testSSHKey}/id_ed25519.pub";
      };

      testVMRunner = import ./lib/make-vm.nix {
        name = "run-test-vm";
        nixosConfig = testVM;
        inherit hostPkgs spiritBin;
      };

      runTests = hostPkgs.writeShellApplication {
        name = "spirits-test";
        runtimeInputs = with hostPkgs; [
          openssh
          curl
          coreutils
          gnugrep
        ];
        text = ''
          exec ${./tests/run-tests.sh} ${testVMRunner}/bin/run-test-vm ${testSSHKey}/id_ed25519 "$@"
        '';
      };
    in
    {
      nixosModules.default = {
        imports = [
          ./modules/nixos/guest.nix
          ./modules/nixos/virtio-fs.nix
        ];
      };

      darwinModules.default = import ./modules/darwin/vms.nix { inherit spiritBin; };

      packages.${darwinSystem} = {
        inherit run-spirit;
        test-vm = testVMRunner;
        run-tests = runTests;
      };
    };
}

{
  nixpkgs,
  spirits,
}:
{
  name,
  modules ? [ ],
  testScript,
  needsSudo ? false,
}:
let
  darwinSystem = "aarch64-darwin";
  hostPkgs = nixpkgs.legacyPackages.${darwinSystem};

  spiritBin = "${spirits.packages.${darwinSystem}.run-spirit}/bin/run-spirit";

  testSSHKey =
    hostPkgs.runCommand "test-ssh-key-${name}"
      {
        nativeBuildInputs = [ hostPkgs.openssh ];
      }
      ''
        mkdir -p $out
        ssh-keygen -t ed25519 -f $out/id_ed25519 -N "" -q
      '';

  sshPubKey = builtins.readFile "${testSSHKey}/id_ed25519.pub";

  testVM = nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      spirits.nixosModules.default
      (import ./base-vm.nix { inherit sshPubKey; })
    ]
    ++ modules;
  };

  testVMRunner = import ../../lib/make-vm.nix {
    name = "run-test-vm-${name}";
    nixosConfig = testVM;
    inherit hostPkgs spiritBin;
  };

  runTests = hostPkgs.writeShellApplication {
    name = "spirits-test-${name}";
    runtimeInputs = with hostPkgs; [
      openssh
      curl
      coreutils
      gnugrep
    ];
    text =
      (
        if needsSudo then
          ''
            # Pre-cache sudo credentials — the VM process runs backgrounded
            # with no stdin, so sudo cannot prompt interactively.
            sudo -v
          ''
        else
          ""
      )
      + ''
        exec ${./run-tests.sh} ${testVMRunner}/bin/run-test-vm-${name} ${testSSHKey}/id_ed25519 ${testScript} "$@"
      '';
  };
in
{
  vm = testVMRunner;
  run-tests = runTests;
}

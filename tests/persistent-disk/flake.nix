{
  description = "spirits - persistent disk test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    spirits.url = "../..";
    spirits.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      spirits,
      ...
    }:
    let
      mkTest = import ../lib/mk-test.nix { inherit nixpkgs spirits; };
      test = mkTest {
        name = "persistent-disk";
        modules = [
          {
            spirit.disk = {
              enable = true;
              hostPath = "/tmp/spirits-test-persistent-disk.img";
            };
          }
        ];
        testScript = ./tests.sh;
      };
    in
    {
      packages.aarch64-darwin = {
        inherit (test) vm run-tests;
      };
    };
}

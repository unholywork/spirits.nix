{
  description = "spirits - home-manager VM test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    spirits.url = "../..";
    spirits.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      spirits,
      home-manager,
      ...
    }:
    let
      mkTest = import ../lib/mk-test.nix { inherit nixpkgs spirits; };
      test = mkTest {
        name = "home-manager";
        modules = [
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.testuser = {
              home.stateVersion = "25.11";
              home.packages = [ ];
              programs.bash.enable = true;
              programs.git = {
                enable = true;
                settings = {
                  user.name = "Test User";
                  user.email = "test@example.com";
                };
              };
            };

            users.users.testuser = {
              isNormalUser = true;
              home = "/home/testuser";
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

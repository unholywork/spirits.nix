{
  nixpkgs,
  spiritsModule,
  sshPubKey,
}:

nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";
  modules = [
    spiritsModule
    (
      { pkgs, ... }:
      {
        spirit = {
          cpus = 4;
          memoryMiB = 4096;
          staticIP = "192.168.64.200";
        };

        # SSH for test execution
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "yes";
        };
        users.users.root = {
          password = "root";
          openssh.authorizedKeys.keys = [ sshPubKey ];
        };

        # Signal boot completion on serial console
        systemd.services.test-ready = {
          description = "Signal test readiness on serial console";
          after = [
            "multi-user.target"
            "sshd.service"
          ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = pkgs.writeShellScript "test-ready" ''
              echo "SPIRITS_TEST_READY" > /dev/hvc0
            '';
          };
        };

        environment.systemPackages = with pkgs; [
          curl
          nix
        ];

        documentation.enable = false;
        system.stateVersion = "24.11";
      }
    )
  ];
}

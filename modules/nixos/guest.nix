{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.spirit;
in
{
  options.spirit = {
    cpus = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Number of virtual CPUs.";
    };

    memoryMiB = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Memory in MiB.";
    };

    networking = {
      mode = lib.mkOption {
        type = lib.types.enum [
          "nat"
          "bridged"
        ];
        default = "nat";
        description = "Networking mode. NAT uses Apple's built-in virtual network; bridged attaches directly to a host interface (requires sudo).";
      };

      nat = {
        staticIP = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Static IP address on the NAT subnet (192.168.64.0/24). Uses DHCP when null.";
        };
      };

      bridged = {
        interface = lib.mkOption {
          type = lib.types.str;
          default = "en0";
          description = "Host network interface to bridge to.";
        };
      };
    };

    stateDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host directory for VM save/restore state files.";
    };

    hostKeys = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = "Path inside the guest where the key is mounted (e.g. from a virtiofs share).";
            };
            type = lib.mkOption {
              type = lib.types.enum [
                "ed25519"
                "rsa"
                "ecdsa"
              ];
              default = "ed25519";
              description = "SSH host key type.";
            };
          };
        }
      );
      default = [ ];
      description = "SSH host keys to install from virtiofs-mounted secrets. Disables auto-generation when set.";
    };

    ephemeralDisk = {
      enable = lib.mkEnableOption "ephemeral root disk (reset on each boot)";
      sizeMiB = lib.mkOption {
        type = lib.types.int;
        default = 8192;
        description = "Ephemeral disk image size in MiB.";
      };
    };

    disk = {
      enable = lib.mkEnableOption "persistent disk";
      device = lib.mkOption {
        type = lib.types.str;
        default = if cfg.ephemeralDisk.enable then "/dev/vdc" else "/dev/vdb";
        defaultText = lib.literalExpression ''if cfg.ephemeralDisk.enable then "/dev/vdc" else "/dev/vdb"'';
        description = "Block device path for the persistent disk.";
      };
      fsType = lib.mkOption {
        type = lib.types.str;
        default = "ext4";
        description = "Filesystem type for the persistent disk.";
      };
      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/persist";
        description = "Mount point for the persistent disk.";
      };
      hostPath = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Path to the disk image on the host.";
      };
      hostSizeMiB = lib.mkOption {
        type = lib.types.int;
        default = 65536;
        description = "Disk image size in MiB (created on first run).";
      };
    };
  };

  config = lib.mkMerge [
    # Core guest configuration (always applied)
    {
      # Direct kernel boot — no bootloader needed
      boot.loader.grub.enable = false;

      # Kernel modules required for virtio devices
      boot.initrd.availableKernelModules = [
        "virtio_console"
        "virtiofs"
        "virtio_net"
        "virtio_pci"
        "virtio_blk"
        "overlay"
        "squashfs"
      ];

      # Serial console output
      boot.kernelParams = [ "console=hvc0" ];

      # Stateless root on tmpfs
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
        options = [
          "defaults"
          "size=2G"
          "mode=755"
        ];
      };

      # Read-only store image (squashfs) attached as the first virtio-blk disk.
      # Built from the system closure on the host; sidesteps virtio-fs concurrency
      # issues when multiple spirits share the host's /nix/store.
      fileSystems."/nix/.ro-store" = {
        device = "/dev/vda";
        fsType = "squashfs";
        options = [ "ro" ];
        neededForBoot = true;
      };

      fileSystems."/nix/.rw-store" = lib.mkIf (!cfg.ephemeralDisk.enable) {
        device = "none";
        fsType = "tmpfs";
        options = [
          "mode=755"
          "size=512M"
        ];
        neededForBoot = true;
      };

      # make-squashfs places store paths directly at the squashfs root (their
      # basenames), not under /nix/store/. Match the NixOS ISO image overlay
      # layout: lowerdir is the squashfs root itself.
      fileSystems."/nix/store" = {
        fsType = "overlay";
        overlay = {
          lowerdir = [ "/nix/.ro-store" ];
          upperdir = "/nix/.rw-store/upper";
          workdir = "/nix/.rw-store/work";
        };
        depends = [
          "/nix/.ro-store"
        ] ++ lib.optional (!cfg.ephemeralDisk.enable) "/nix/.rw-store";
        neededForBoot = true;
      };

      # Populate the nix DB from the registration shipped inside the store image.
      boot.postBootCommands = ''
        mkdir -p /nix/var/nix/db /nix/var/nix/gcroots /nix/var/nix/profiles /nix/var/nix/userpool
        mkdir -p /nix/var/nix/daemon-socket
        chmod 0755 /nix/var/nix/daemon-socket

        if [ ! -e /nix/var/nix/db/db.sqlite ]; then
          ${config.nix.package.out}/bin/nix-store --load-db < /nix/.ro-store/nix-path-registration
        fi
      '';

      # Skip firewall behind NAT for faster boot
      networking.firewall.enable = lib.mkDefault (cfg.networking.mode == "bridged");

      # Networking via systemd-networkd
      networking.useNetworkd = true;
      networking.useDHCP = false;
      systemd.network.enable = true;
      systemd.network.wait-online.enable = false;
    }

    # Networking: DHCP by default
    {
      systemd.network.networks."10-virtio" = {
        matchConfig.Name = "en* eth*";
        networkConfig.DHCP = lib.mkDefault "yes";
        dhcpV4Config.ClientIdentifier = lib.mkDefault "mac";
      };
    }

    # NAT static IP override
    (lib.mkIf (cfg.networking.mode == "nat" && cfg.networking.nat.staticIP != null) {
      systemd.network.networks."10-virtio" = {
        networkConfig = {
          DHCP = lib.mkForce "no";
          Address = [ "${cfg.networking.nat.staticIP}/24" ];
          Gateway = [ "192.168.64.1" ];
          DNS = [ "192.168.64.1" ];
        };
      };
    })

    # SSH host keys from virtiofs-mounted secrets
    (lib.mkIf (cfg.hostKeys != [ ]) {
      # Disable automatic host key generation — we provide our own
      services.openssh.hostKeys = lib.mkForce [ ];
      services.openssh.generateHostKeys = false;

      systemd.services.install-ssh-host-keys = {
        description = "Install SSH host keys from host secrets";
        wantedBy = [ "sshd.service" ];
        before = [ "sshd.service" ];
        serviceConfig.Type = "oneshot";
        script = lib.concatStringsSep "\n" (
          map (
            key:
            let
              dest = "/etc/ssh/ssh_host_${key.type}_key";
            in
            ''
              mkdir -p /etc/ssh
              cp "${key.source}" "${dest}"
              chmod 600 "${dest}"
              if [ ! -f "${dest}.pub" ]; then
                ${pkgs.openssh}/bin/ssh-keygen -y -f "${dest}" > "${dest}.pub"
              fi
            ''
          ) cfg.hostKeys
        );
      };
    })

    # Ephemeral root disk — replaces tmpfs root with a disk image that is reset on each boot
    (lib.mkIf cfg.ephemeralDisk.enable {
      boot.initrd.systemd.storePaths = [
        "${pkgs.e2fsprogs}/bin/tune2fs"
        "${pkgs.e2fsprogs}/sbin/mke2fs"
      ];

      # Format the empty disk before fsck/mount runs
      boot.initrd.systemd.services.format-ephemeral-disk = {
        description = "Format ephemeral disk if empty";
        requires = [ "dev-vdb.device" ];
        after = [ "dev-vdb.device" ];
        requiredBy = [ "sysroot.mount" ];
        before = [
          "systemd-fsck-root.service"
          "sysroot.mount"
        ];
        unitConfig = {
          DefaultDependencies = false;
          ConditionPathExists = "/etc/initrd-release";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if ! ${pkgs.e2fsprogs}/bin/tune2fs -l /dev/vdb >/dev/null 2>&1; then
            ${pkgs.e2fsprogs}/sbin/mke2fs -t ext4 -q /dev/vdb
          fi
        '';
      };

      fileSystems."/" = lib.mkForce {
        device = "/dev/vdb";
        fsType = "ext4";
      };
    })

    # Persistent disk
    (lib.mkIf cfg.disk.enable {
      boot.initrd.systemd.storePaths = lib.mkIf (cfg.disk.fsType == "ext4") [
        "${pkgs.e2fsprogs}/bin/tune2fs"
        "${pkgs.e2fsprogs}/sbin/mke2fs"
      ];

      # Format a brand new persistent disk image before fsck/mount runs.
      boot.initrd.systemd.services.format-persistent-disk = lib.mkIf (cfg.disk.fsType == "ext4") {
        description = "Format persistent disk if empty";
        requires = [ "${utils.escapeSystemdPath cfg.disk.device}.device" ];
        after = [ "${utils.escapeSystemdPath cfg.disk.device}.device" ];
        requiredBy = [ "initrd-fs.target" ];
        before = [ "initrd-fs.target" ];
        unitConfig = {
          DefaultDependencies = false;
          ConditionPathExists = "/etc/initrd-release";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if ! ${pkgs.e2fsprogs}/bin/tune2fs -l ${cfg.disk.device} >/dev/null 2>&1; then
            ${pkgs.e2fsprogs}/sbin/mke2fs -t ext4 -q ${cfg.disk.device}
          fi
        '';
      };

      fileSystems.${cfg.disk.mountPoint} = {
        device = cfg.disk.device;
        fsType = cfg.disk.fsType;
      };
    })
  ];
}

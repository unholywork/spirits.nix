# Unholy Spirits

A nix-darwin module to declare ephemeral NixOS VMs, which run on Apple's Virtualization.framework.

Disclaimer: Code is AI generated.

## Requirements

A remote Linux builder is required to build the NixOS system. You can enable a VM-based builder in your nix-darwin config:

```nix
nix.linux-builder.enable = true;
```

## Usage

```nix
# flake.nix
{
  # <...>
  inputs.spirits.url = "github:unholywork/spirits.nix";
  spirits.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, nix-darwin, spirits }: {
    darwinConfigurations.my-mac = nix-darwin.lib.darwinSystem {
      modules = [
        spirits.darwinModules.default
        {
          spirits.my-vm = nixpkgs.lib.nixosSystem {
            system = "aarch64-linux";
            modules = [
              spirits.nixosModules.default
              {
                spirit = {
                  cpus = 4;
                  memoryMiB = 4096;
                };
              }
            ];
          };
        }
      ];
    };
  };
}
```

After switching, run `run-<vm name>` to launch the VM.

### Configuration options

```nix
{
  spirit = {
    cpus = 4; # default: 4
    memoryMiB = 4096; # default: 4096

    # Shared directories:
    sharedDirectories.projects = {
      hostPath = "/Users/me/projects";
      mountPoint = "/projects";
      readOnly = true; # default: false
    };

    # Attach a persistent disk image:
    disk = {
      enable = true; # default: false
      hostPath = "/Users/me/spirits/my-vm.img"; # default: ""
      hostSizeMiB = 65536; # default: 65536
      mountPoint = "/persist"; # default: "/persist"
      fsType = "ext4"; # default: "ext4"
    };

    # Install SSH host keys:
    hostKeys = [
      {
        source = "/run/host-secrets/ssh_host_key"; # needs to be mounted via a shared directory
        type = "ed25519";
      }
    ];
  };
}
```

## VM Control

While a VM is running, press **Ctrl+]** to pause it and open the control menu:

```
  spirits  (VM paused)
  ─────────────────────
  r / Enter / Esc  resume
  q                quit gracefully
  k                force kill
```

## Implementation Details

- Guests use a tmpfs root FS.
- The hosts `/nix/store` is shared (RO) with guests.
- Guests create a tmpfs overlay over the shared `/nix/store`.
- Network is provided via NAT.

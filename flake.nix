{
  description = "Werewolf game server deployment";

  inputs = {
    # Use stable for servers — less churn, longer support window.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Only for packages that need fixes stable hasn't picked up yet (see overlay below).
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Declarative disk partitioning — used by nixos-anywhere.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The game itself — pin to a specific commit via flake.lock.
    # Run `nix flake update werewolf` in this directory to pull the latest.
    werewolf = {
      url = "github:Simon-Peleska/werewolf-go";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # # Not following our nixpkgs — its uv2nix build expects unstable.
    # hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, werewolf /* , hermes-agent */ }:
  let
    system = "x86_64-linux";
    pkgsUnstable = import nixpkgs-unstable {
      inherit system;
      config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "claude-code";
    };
  in {
    nixosConfigurations.server-1 = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inputs = { inherit werewolf; }; inherit pkgsUnstable; };
      modules = [
        disko.nixosModules.disko
        werewolf.nixosModules.werewolf
        # hermes-agent.nixosModules.default
        ./configuration.nix
        ./daily-check.nix
        # Gitea 1.27.3 on 26.05 has ~27 CVEs (incl. SSRF, SSH auth bypass) only
        # fixed in v28+. Drop this once 26.05 ships a fixed gitea.
        {
          nixpkgs.overlays = [
            (final: prev: {
              gitea = pkgsUnstable.gitea;
            })
          ];
        }
      ];
    };
  };
}

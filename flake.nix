{
  description = "Werewolf game server deployment";

  inputs = {
    # Use stable for servers — less churn, longer support window.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

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

    # Not following our nixpkgs — its uv2nix build expects unstable.
    hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs = { self, nixpkgs, disko, werewolf, hermes-agent }: {
    nixosConfigurations.server-1 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inputs = { inherit werewolf; }; };
      modules = [
        disko.nixosModules.disko
        werewolf.nixosModules.werewolf
        hermes-agent.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}

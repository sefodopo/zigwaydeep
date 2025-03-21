{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          (_: prev: {
            zig = prev.zig.overrideAttrs (prevAttrs: {
              patches = prevAttrs.patches ++ [
                ./zig-build-watch-fix.patch
              ];
            });
          })
        ];
      };
    in
    {
      devShells."${system}".default = pkgs.mkShell {
        packages = [
          pkgs.zig
          pkgs.zls
        ];
      };
    };
}

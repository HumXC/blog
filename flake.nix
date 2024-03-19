{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, flake-utils, nixpkgs }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        hugo-new-content = pkgs.writeScriptBin "hugo-new-content" ''${pkgs.hugo}/bin/hugo new content "posts/$*.md"'';
        hugo-server = pkgs.writeScriptBin "hugo-server" ''${pkgs.hugo}/bin/hugo server -D'';
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.hugo
            hugo-new-content
            hugo-server
          ];
          shellHook = ''
            echo "new-content <name> : create a new post"
            echo "server : start a hugo server with \"-D\""
          '';
        };
      }
    );
}

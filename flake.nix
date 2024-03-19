{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, flake-utils, nixpkgs }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        hugo-new-content = pkgs.writeScriptBin "hugo-new-content" ''
          name=post/$*
          if [[ $name == *" "* ]]; then
            echo "Error: The name contains spaces!"
            exit 1
          fi
          mkdir "content/$name"
          ${pkgs.hugo}/bin/hugo new content "$name/index.md"
        '';
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
            echo "hugo-new-content <name> : create a new post"
            echo "hugo-server : start a hugo server with \"-D\""
          '';
        };
      }
    );
}

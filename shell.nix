with import <nixpkgs> { };
mkShell {
  buildInputs = [ hugo ];
  shellHook = ''
    function new-content() {
      hugo new content \"posts/"$*".md\"
    }
    function server() {
      hugo server -D
    }

    echo "new-content <name> : create a new post"
    echo "server : start a hugo server with \"-D\""
  '';
}

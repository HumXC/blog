cat >go.mod <<EOF
module github.com/HumXC/blog

go 1.20

EOF
hugo --gc --minify --ignoreCache --verbose

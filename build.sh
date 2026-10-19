#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
version="1.2.2"
mkdir -p dist
tar --owner=0 --group=0 --numeric-owner -czf "dist/netpilot-router-$version.tar.gz" files install.sh README.md CHANGELOG.md NOTICE.md VALIDATION.md
(cd dist && sha256sum "netpilot-router-$version.tar.gz" > "netpilot-router-$version.sha256")
printf 'Built %s\n' "dist/netpilot-router-$version.tar.gz"

#!/bin/sh
# Fetches Parsec SDK 6.0 for Windows (the same version as the iPad's ParsecSDK.framework) from a
# mirror of the old parsec-cloud/parsec-sdk repository, pinned and checked.
set -eu
cd "$(dirname "$0")"
base=https://raw.githubusercontent.com/mbroemme/parsec-sdk/14222ac25be3bc28c49b4858213a737642031513/sdk

fetch() {
	if [ -f "$2" ] && echo "$1  $2" | shasum -a 256 -c - >/dev/null 2>&1; then
		return
	fi
	curl -fsSL -o "$2" "$base/$3"
	echo "$1  $2" | shasum -a 256 -c -
}

fetch 9944bf9f7ebc4b39c458fc4306e673878de44a4983e3ab880a239ce14318eb22 parsec.h parsec.h
fetch 563d173809922b0631a3f22d93aa8b97d9d43b196083c3244e671bada7261e11 parsec-dso.h parsec-dso.h
fetch a57fd8b7b02ff7589d1bbb21ba3b0afff1685e4616351e9d21b24919a5882f08 parsec.dll windows/parsec.dll

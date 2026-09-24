#!/bin/sh
# Regenerate both examples and compare them with the committed files. Then
# compile both with -vet -strict-style and run the helper tests on the boxed
# one. The tests share one stub allocator, so they run on one thread.
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

for example in example example/boxed; do
	mkdir -p "$out/$example"
	roc glue ./OdinGlue.roc "$out/$example" "$example/platform/main.roc" > /dev/null
	diff "$out/$example/roc_platform_abi.odin" "$example/expected/roc_platform_abi.odin"
	echo "== $example matches its expected file"
done

mkdir -p "$out/build" "$out/test"
cp example/expected/roc_platform_abi.odin example/test/host_stub.odin "$out/build"
odin build "$out/build" -build-mode:static -out:"$out/build.a" -vet -strict-style
echo "== example compiles"

cp example/boxed/expected/roc_platform_abi.odin example/test/*.odin "$out/test"
odin test "$out/test" -vet -strict-style -define:ODIN_TEST_THREADS=1

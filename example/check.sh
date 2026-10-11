#!/bin/sh
# Regenerate the examples and compare them with the committed files. Then
# compile them with -vet -strict-style, run the helper tests on the boxed one
# and the layout tests on the unions one. The tests share one stub allocator,
# so they run on one thread.
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

for example in example example/boxed example/unions; do
	mkdir -p "$out/$example"
	# The glue cache can return the output of an older spec for the same platform.
	roc glue --no-cache ./OdinGlue.roc "$out/$example" "$example/platform/main.roc" > /dev/null
	diff "$out/$example/roc_platform_abi.odin" "$example/expected/roc_platform_abi.odin"
	echo "== $example matches its expected file"
done

mkdir -p "$out/build" "$out/test"
cp example/expected/roc_platform_abi.odin example/test/host_stub.odin "$out/build"
odin build "$out/build" -build-mode:static -out:"$out/build.a" -vet -strict-style
echo "== example compiles"

cp example/boxed/expected/roc_platform_abi.odin example/test/*.odin "$out/test"
odin test "$out/test" -out:"$out/test.bin" -vet -strict-style -define:ODIN_TEST_THREADS=1

mkdir -p "$out/unions_test"
cp example/unions/expected/roc_platform_abi.odin example/test/host_stub.odin example/unions/test/*.odin "$out/unions_test"
odin test "$out/unions_test" -out:"$out/unions_test.bin" -vet -strict-style -define:ODIN_TEST_THREADS=1

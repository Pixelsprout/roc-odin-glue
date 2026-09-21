# Example

A minimal platform with no host and no build target, so `roc glue` runs
against it directly:

    roc glue ../OdinGlue.roc /tmp/out ./platform/main.roc
    diff /tmp/out/roc_platform_abi.odin expected/roc_platform_abi.odin

`expected/roc_platform_abi.odin` is the committed output. It compiles as Odin
with every assertion holding:

    odin build <dir containing a copy of it> -build-mode:static -out:/tmp/a.a -vet -strict-style

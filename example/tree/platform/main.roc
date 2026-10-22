platform ""
    requires {} {
        view : U64 -> List(Element),
        title : U64 -> Str,
    }
    exposes []
    packages { roc: "nightly-2026-10-11-7d256b9" }
    provides {
        "roc_view": view_for_host,
        "roc_title": title_for_host,
    }

# A union that refers to itself through a List is stored inline, with no
# compiler-inserted Box, so the host can walk and free it. Only a nominal
# recursive union crosses the host boundary.
Element := [Box(BoxConfig, List(Element)), Text(Text)]

BoxConfig : { gap : F32, background : U32 }

Text : { str : Str, size : F32 }

view_for_host : U64 -> List(Element)
view_for_host = |n| view(n)

# A Str outside the nominal Element reaches the glue under a second type id.
title_for_host : U64 -> Str
title_for_host = |n| title(n)

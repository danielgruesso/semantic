# This file lets us share warnings and such across the project

load(
    "@rules_haskell//haskell:defs.bzl",
    "haskell_library",
    "haskell_test",
    "haskell_toolchain_library",
)

STANDARD_GHC_WARNINGS = [
    "-O0",
    "-v1",
    "-j8",
    "-fdiagnostics-color=always",
    "-ferror-spans",
    "-Weverything",
    "-Wno-missing-local-signatures",
    "-Wno-missing-import-lists",
    "-Wno-implicit-prelude",
    "-Wno-safe",
    "-Wno-unsafe",
    "-Wno-name-shadowing",
    "-Wno-monomorphism-restriction",
    "-Wno-missed-specialisations",
    "-Wno-all-missed-specialisations",
    "-Wno-star-is-type",
    "-Wno-missing-deriving-strategies",
]

STANDARD_EXECUTABLE_FLAGS = [
    "-threaded",
]

def semantic_language_library(language, name, srcs, **kwargs):
    haskell_library(
        name = name,
        compiler_flags = STANDARD_GHC_WARNINGS,
        srcs = srcs,
        extra_srcs = ["//vendor:" + language + "-node-types.json"],
        deps = [
            ":base",
            "//semantic-analysis:lib",
            "//semantic-ast:lib",
            "//semantic-core:lib",
            "//semantic-proto:lib",
            "//semantic-scope-graph:lib",
            "//semantic-source:lib",
            "//semantic-tags:lib",
            "@stackage//:aeson",
            "@stackage//:algebraic-graphs",
            "@stackage//:containers",
            "@stackage//:fused-effects",
            "@stackage//:fused-syntax",
            "@stackage//:generic-lens",
            "@stackage//:generic-monoid",
            "@stackage//:hashable",
            "@stackage//:lens",
            "@stackage//:pathtype",
            "@stackage//:semilattices",
            "@stackage//:template-haskell",
            "@stackage//:text",
            "@stackage//:tree-sitter",
            "@stackage//:tree-sitter-" + language,
        ],
    )

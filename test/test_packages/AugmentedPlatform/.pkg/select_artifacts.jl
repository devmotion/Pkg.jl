using TOML, Artifacts, Base.BinaryPlatforms

try
    using StructIO
catch e
    if isa(e, ArgumentError)
        error("select_artifacts.jl not run in proper environment; could not import StructIO!")
    else
        rethrow(e)
    end
end
include("./platform_augmentation.jl")

# Next, select all artifacts with an augmented platform
artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
platform = augment_platform!(HostPlatform())
artifacts = select_downloadable_artifacts(artifacts_toml; platform)
TOML.print(stdout, artifacts)

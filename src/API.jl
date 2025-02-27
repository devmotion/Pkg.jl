# This file is a part of Julia. License is MIT: https://julialang.org/license

module API

using UUIDs
using Printf
import Random
using Dates
import LibGit2
import Logging
using Serialization

import ..depots, ..depots1, ..logdir, ..devdir, ..printpkgstyle
import ..Operations, ..GitTools, ..Pkg, ..Registry
import ..can_fancyprint, ..pathrepr, ..isurl
using ..Types, ..TOML
using ..Types: VersionTypes
using Base.BinaryPlatforms
import ..DEFAULT_IO
using ..Artifacts: artifact_paths
using ..MiniProgressBars

include("generate.jl")

Base.@kwdef struct PackageInfo
    name::String
    version::Union{Nothing,VersionNumber}
    tree_hash::Union{Nothing,String}
    is_direct_dep::Bool
    is_pinned::Bool
    is_tracking_path::Bool
    is_tracking_repo::Bool
    is_tracking_registry::Bool
    git_revision::Union{Nothing,String}
    git_source::Union{Nothing,String}
    source::String
    dependencies::Dict{String,UUID}
end

function Base.:(==)(a::PackageInfo, b::PackageInfo)
    return a.name == b.name && a.version == b.version && a.tree_hash == b.tree_hash &&
        a.is_direct_dep == b.is_direct_dep &&
        a.is_pinned == b.is_pinned && a.is_tracking_path == b.is_tracking_path &&
        a.is_tracking_repo == b.is_tracking_repo &&
        a.is_tracking_registry == b.is_tracking_registry &&
        a.git_revision == b.git_revision && a.git_source == b.git_source &&
        a.source == b.source && a.dependencies == b.dependencies
end

function package_info(env::EnvCache, pkg::PackageSpec)::PackageInfo
    entry = manifest_info(env.manifest, pkg.uuid)
    if entry === nothing
        pkgerror("expected package $(err_rep(pkg)) to exist in the manifest",
                 " (use `resolve` to populate the manifest)")
    end
    package_info(env, pkg, entry)
end

function package_info(env::EnvCache, pkg::PackageSpec, entry::PackageEntry)::PackageInfo
    git_source = pkg.repo.source === nothing ? nothing :
        isurl(pkg.repo.source) ? pkg.repo.source :
        Operations.project_rel_path(env, pkg.repo.source)
    info = PackageInfo(
        name                 = pkg.name,
        version              = pkg.version != VersionSpec() ? pkg.version : nothing,
        tree_hash            = pkg.tree_hash === nothing ? nothing : string(pkg.tree_hash), # TODO or should it just be a SHA?
        is_direct_dep        = pkg.uuid in values(env.project.deps),
        is_pinned            = pkg.pinned,
        is_tracking_path     = pkg.path !== nothing,
        is_tracking_repo     = pkg.repo.rev !== nothing || pkg.repo.source !== nothing,
        is_tracking_registry = Operations.is_tracking_registry(pkg),
        git_revision         = pkg.repo.rev,
        git_source           = git_source,
        source               = Operations.project_rel_path(env, Operations.source_path(env.project_file, pkg)),
        dependencies         = copy(entry.deps), #TODO is copy needed?
    )
    return info
end

dependencies() = dependencies(EnvCache())
function dependencies(env::EnvCache)
    pkgs = Operations.load_all_deps(env)
    return Dict(pkg.uuid::UUID => package_info(env, pkg) for pkg in pkgs)
end
function dependencies(fn::Function, uuid::UUID)
    dep = get(dependencies(), uuid, nothing)
    if dep === nothing
        pkgerror("depenendency with UUID `$uuid` does not exist")
    end
    fn(dep)
end


Base.@kwdef struct ProjectInfo
    name::Union{Nothing,String}
    uuid::Union{Nothing,UUID}
    version::Union{Nothing,VersionNumber}
    ispackage::Bool
    dependencies::Dict{String,UUID}
    path::String
end

project() = project(EnvCache())
function project(env::EnvCache)::ProjectInfo
    return ProjectInfo(
        name         = env.pkg === nothing ? nothing : env.pkg.name,
        uuid         = env.pkg === nothing ? nothing : env.pkg.uuid,
        version      = env.pkg === nothing ? nothing : env.pkg.version,
        ispackage    = env.pkg !== nothing,
        dependencies = env.project.deps,
        path         = env.project_file
    )
end

function check_package_name(x::AbstractString, mode=nothing)
    if !Base.isidentifier(x)
        message = "`$x` is not a valid package name"
        if endswith(lowercase(x), ".jl")
            message *= ". Perhaps you meant `$(chop(x; tail=3))`"
        end
        if mode !== nothing && any(occursin.(['\\','/'], x)) # maybe a url or a path
            message *= "\nThe argument appears to be a URL or path, perhaps you meant " *
                "`Pkg.$mode(url=\"...\")` or `Pkg.$mode(path=\"...\")`."
        end
        pkgerror(message)
    end
    return
end
check_package_name(::Nothing, ::Any) = nothing

function require_not_empty(pkgs, f::Symbol)
    isempty(pkgs) && pkgerror("$f requires at least one package")
end

# Provide some convenience calls
for f in (:develop, :add, :rm, :up, :pin, :free, :test, :build, :status)
    @eval begin
        $f(pkg::Union{AbstractString, PackageSpec}; kwargs...) = $f([pkg]; kwargs...)
        $f(pkgs::Vector{<:AbstractString}; kwargs...)          = $f([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
        function $f(pkgs::Vector{PackageSpec}; kwargs...)
            Registry.download_default_registries(DEFAULT_IO[])
            ctx = Context()
            ret = $f(ctx, pkgs; kwargs...)
            $(f in (:add, :up, :pin, :free, :build)) && _auto_precompile(ctx)
            return ret
        end
        $f(ctx::Context; kwargs...) = $f(ctx, PackageSpec[]; kwargs...)
        function $f(; name::Union{Nothing,AbstractString}=nothing, uuid::Union{Nothing,String,UUID}=nothing,
                      version::Union{VersionNumber, String, VersionSpec, Nothing}=nothing,
                      url=nothing, rev=nothing, path=nothing, mode=PKGMODE_PROJECT, subdir=nothing, kwargs...)
            pkg = Package(name=name, uuid=uuid, version=version, url=url, rev=rev, path=path, mode=mode, subdir=subdir)
            # Pkg.status takes a mode argument as well which is a bit ambiguous with the
            # mode argument to the PackageSpec but probably not a problem in practice
            if $f === status
                kwargs = merge((;kwargs...), (:mode => mode,))
            end
            # Handle $f() case
            if pkg == Package()
                $f(PackageSpec[]; kwargs...)
            else
                $f(pkg; kwargs...)
            end
        end
        function $f(pkgs::Vector{<:NamedTuple}; kwargs...)
            $f([Package(;pkg...) for pkg in pkgs]; kwargs...)
        end
    end
end

function develop(ctx::Context, pkgs::Vector{PackageSpec}; shared::Bool=true,
                 preserve::PreserveLevel=PRESERVE_TIERED, platform::AbstractPlatform=HostPlatform(), kwargs...)
    require_not_empty(pkgs, :develop)
    foreach(pkg -> check_package_name(pkg.name, :develop), pkgs)
    pkgs = deepcopy(pkgs) # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

    for pkg in pkgs
        if pkg.name == "julia" # if julia is passed as a package the solver gets tricked
            pkgerror("`julia` is not a valid package name")
        end
        pkg.name === nothing || check_package_name(pkg.name, "develop")
        if pkg.name === nothing && pkg.uuid === nothing && pkg.repo.source === nothing
            pkgerror("name, UUID, URL, or filesystem path specification required when calling `develop`")
        end
        if pkg.repo.rev !== nothing
            pkgerror("rev argument not supported by `develop`; consider using `add` instead")
        end
        if pkg.version != VersionSpec()
            pkgerror("version specification invalid when calling `develop`:",
                     " `$(pkg.version)` specified for package $(err_rep(pkg))")
        end
        # not strictly necessary to check these fields early, but it is more efficient
        if pkg.name !== nothing && (length(findall(x -> x.name == pkg.name, pkgs)) > 1)
            pkgerror("it is invalid to specify multiple packages with the same name: $(err_rep(pkg))")
        end
        if pkg.uuid !== nothing && (length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1)
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
    end

    new_git = handle_repos_develop!(ctx, pkgs, shared)

    for pkg in pkgs
        if Types.collides_with_project(ctx.env, pkg)
            pkgerror("package $(err_rep(pkg)) has the same name or UUID as the active project")
        end
        if length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
    end

    Operations.develop(ctx, pkgs, new_git; preserve=preserve, platform=platform)
    return
end

function add(ctx::Context, pkgs::Vector{PackageSpec}; preserve::PreserveLevel=PRESERVE_TIERED,
             platform::AbstractPlatform=HostPlatform(), kwargs...)
    require_not_empty(pkgs, :add)
    foreach(pkg -> check_package_name(pkg.name, :add), pkgs)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

    for pkg in pkgs
        if pkg.name == "julia" # if julia is passed as a package the solver gets tricked
            pkgerror("`julia` is not a valid package name")
        end
        if pkg.name === nothing && pkg.uuid === nothing && pkg.repo.source === nothing
            pkgerror("name, UUID, URL, or filesystem path specification required when calling `add`")
        end
        pkg.name === nothing || check_package_name(pkg.name, "add")
        if pkg.repo.source !== nothing || pkg.repo.rev !== nothing
            if pkg.version != VersionSpec()
                pkgerror("version specification invalid when tracking a repository:",
                         " `$(pkg.version)` specified for package $(err_rep(pkg))")
            end
        end
        # not strictly necessary to check these fields early, but it is more efficient
        if pkg.name !== nothing && (length(findall(x -> x.name == pkg.name, pkgs)) > 1)
            pkgerror("it is invalid to specify multiple packages with the same name: $(err_rep(pkg))")
        end
        if pkg.uuid !== nothing && (length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1)
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
    end

    repo_pkgs = [pkg for pkg in pkgs if (pkg.repo.source !== nothing || pkg.repo.rev !== nothing)]
    new_git = handle_repos_add!(ctx, repo_pkgs)
    # repo + unpinned -> name, uuid, repo.rev, repo.source, tree_hash
    # repo + pinned -> name, uuid, tree_hash

    Registry.update(; io=ctx.io, force=false)

    project_deps_resolve!(ctx.env, pkgs)
    registry_resolve!(ctx.registries, pkgs)
    stdlib_resolve!(pkgs)
    ensure_resolved(ctx.env.manifest, pkgs, registry=true)

    for pkg in pkgs
        if Types.collides_with_project(ctx.env, pkg)
            pkgerror("package $(err_rep(pkg)) has same name or UUID as the active project")
        end
        if length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
    end

    Operations.add(ctx, pkgs, new_git; preserve, platform)
    return
end

function rm(ctx::Context, pkgs::Vector{PackageSpec}; mode=PKGMODE_PROJECT, kwargs...)
    require_not_empty(pkgs, :rm)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    foreach(pkg -> pkg.mode = mode, pkgs)

    for pkg in pkgs
        if pkg.name === nothing && pkg.uuid === nothing
            pkgerror("name or UUID specification required when calling `rm`")
        end
        if !(pkg.version == VersionSpec() && pkg.pinned == false &&
             pkg.tree_hash === nothing && pkg.repo.source === nothing &&
             pkg.repo.rev === nothing && pkg.path === nothing)
            pkgerror("packages may only be specified by name or UUID when calling `rm`")
        end
    end

    Context!(ctx; kwargs...)

    project_deps_resolve!(ctx.env, pkgs)
    manifest_resolve!(ctx.env.manifest, pkgs)
    ensure_resolved(ctx.env.manifest, pkgs)

    Operations.rm(ctx, pkgs)
    return
end

function up(ctx::Context, pkgs::Vector{PackageSpec};
            level::UpgradeLevel=UPLEVEL_MAJOR, mode::PackageMode=PKGMODE_PROJECT,
            update_registry::Bool=true, kwargs...)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    foreach(pkg -> pkg.mode = mode, pkgs)

    Context!(ctx; kwargs...)
    if update_registry
        Registry.download_default_registries(ctx.io)
        Registry.update(; io=ctx.io, force=true)
        copy!(ctx.registries, Registry.reachable_registries())
    end
    Operations.prune_manifest(ctx.env)
    if isempty(pkgs)
        if mode == PKGMODE_PROJECT
            for (name::String, uuid::UUID) in ctx.env.project.deps
                push!(pkgs, PackageSpec(name=name, uuid=uuid))
            end
        elseif mode == PKGMODE_MANIFEST
            for (uuid, entry) in ctx.env.manifest
                push!(pkgs, PackageSpec(name=entry.name, uuid=uuid))
            end
        end
    else
        project_deps_resolve!(ctx.env, pkgs)
        manifest_resolve!(ctx.env.manifest, pkgs)
        ensure_resolved(ctx.env.manifest, pkgs)
    end
    Operations.up(ctx, pkgs, level)
    return
end

resolve(; kwargs...) = resolve(Context(); kwargs...)
function resolve(ctx::Context; kwargs...)
    up(ctx; level=UPLEVEL_FIXED, mode=PKGMODE_MANIFEST, update_registry=false, kwargs...)
    return nothing
end

function pin(ctx::Context, pkgs::Vector{PackageSpec}; kwargs...)
    require_not_empty(pkgs, :pin)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

    for pkg in pkgs
        if pkg.name === nothing && pkg.uuid === nothing
            pkgerror("name or UUID specification required when calling `pin`")
        end
        if pkg.repo.source !== nothing
            pkgerror("repository specification invalid when calling `pin`:",
                     " `$(pkg.repo.source)` specified for package $(err_rep(pkg))")
        end
        if pkg.repo.rev !== nothing
            pkgerror("git revision specification invalid when calling `pin`:",
                     " `$(pkg.repo.rev)` specified for package $(err_rep(pkg))")
        end
        if pkg.version.ranges[1].lower != pkg.version.ranges[1].upper # TODO test this
            pkgerror("pinning a package requires a single version, not a versionrange")
        end
    end

    foreach(pkg -> pkg.mode = PKGMODE_PROJECT, pkgs)
    project_deps_resolve!(ctx.env, pkgs)
    ensure_resolved(ctx.env.manifest, pkgs)
    Operations.pin(ctx, pkgs)
    return
end

function free(ctx::Context, pkgs::Vector{PackageSpec}; kwargs...)
    require_not_empty(pkgs, :free)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

    for pkg in pkgs
        if pkg.name === nothing && pkg.uuid === nothing
            pkgerror("name or UUID specification required when calling `free`")
        end
        if !(pkg.version == VersionSpec() && pkg.pinned == false &&
             pkg.tree_hash === nothing && pkg.repo.source === nothing &&
             pkg.repo.rev === nothing && pkg.path === nothing)
            pkgerror("packages may only be specified by name or UUID when calling `free`")
        end
    end

    foreach(pkg -> pkg.mode = PKGMODE_MANIFEST, pkgs)
    manifest_resolve!(ctx.env.manifest, pkgs)
    ensure_resolved(ctx.env.manifest, pkgs)

    Operations.free(ctx, pkgs)
    return
end

function test(ctx::Context, pkgs::Vector{PackageSpec};
              coverage=false, test_fn=nothing,
              julia_args::Union{Cmd, AbstractVector{<:AbstractString}}=``,
              test_args::Union{Cmd, AbstractVector{<:AbstractString}}=``,
              kwargs...)
    julia_args = Cmd(julia_args)
    test_args = Cmd(test_args)
    pkgs = deepcopy(pkgs) # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)
    if isempty(pkgs)
        ctx.env.pkg === nothing && pkgerror("trying to test unnamed project") #TODO Allow this?
        push!(pkgs, ctx.env.pkg)
    else
        project_resolve!(ctx.env, pkgs)
        project_deps_resolve!(ctx.env, pkgs)
        manifest_resolve!(ctx.env.manifest, pkgs)
        ensure_resolved(ctx.env.manifest, pkgs)
    end
    Operations.test(ctx, pkgs; coverage=coverage, test_fn=test_fn, julia_args=julia_args, test_args=test_args)
    return
end

const UsageDict = Dict{String,DateTime}
const UsageByDepotDict = Dict{String,UsageDict}

"""
    gc(ctx::Context=Context(); collect_delay::Period=Day(7), verbose=false, kwargs...)

Garbage-collect package and artifact installations by sweeping over all known
`Manifest.toml` and `Artifacts.toml` files, noting those that have been deleted, and then
finding artifacts and packages that are thereafter not used by any other projects,
marking them as "orphaned".  This method will only remove orphaned objects (package
versions, artifacts, and scratch spaces) that have been continually un-used for a period
of `collect_delay`; which defaults to seven days.

Use verbose mode (`verbose=true`) for detailed output.
"""
function gc(ctx::Context=Context(); collect_delay::Period=Day(7), verbose=false, kwargs...)
    Context!(ctx; kwargs...)
    env = ctx.env

    # First, we load in our `manifest_usage.toml` files which will tell us when our
    # "index files" (`Manifest.toml`, `Artifacts.toml`) were last used.  We will combine
    # this knowledge across depots, condensing it all down to a single entry per extant
    # index file, to manage index file growth with would otherwise continue unbounded. We
    # keep the lists of index files separated by depot so that we can write back condensed
    # versions that are only ever subsets of what we read out of them in the first place.

    # Collect last known usage dates of manifest and artifacts toml files, split by depot
    manifest_usage_by_depot = UsageByDepotDict()
    artifact_usage_by_depot = UsageByDepotDict()

    # Collect both last known usage dates, as well as parent projects for each scratch space
    scratch_usage_by_depot = UsageByDepotDict()
    scratch_parents_by_depot = Dict{String, Dict{String, Set{String}}}()

    # Load manifest files from all depots
    for depot in depots()
        # When a manifest/artifact.toml is installed/used, we log it within the
        # `manifest_usage.toml` files within `write_env_usage()` and `bind_artifact!()`
        function reduce_usage!(f::Function, usage_filepath)
            if !isfile(usage_filepath)
                return
            end

            for (filename, infos) in parse_toml(usage_filepath)
                f.(Ref(filename), infos)
            end
        end

        # Extract usage data from this depot, (taking only the latest state for each
        # tracked manifest/artifact.toml), then merge the usage values from each file
        # into the overall list across depots to create a single, coherent view across
        # all depots.
        usage = UsageDict()
        reduce_usage!(joinpath(logdir(depot), "manifest_usage.toml")) do filename, info
            # For Manifest usage, store only the last DateTime for each filename found
            usage[filename] = max(get(usage, filename, DateTime(0)), DateTime(info["time"]))
        end
        manifest_usage_by_depot[depot] = usage

        usage = UsageDict()
        reduce_usage!(joinpath(logdir(depot), "artifact_usage.toml")) do filename, info
            # For Artifact usage, store only the last DateTime for each filename found
            usage[filename] = max(get(usage, filename, DateTime(0)), DateTime(info["time"]))
        end
        artifact_usage_by_depot[depot] = usage

        # track last-used
        usage = UsageDict()
        parents = Dict{String, Set{String}}()
        reduce_usage!(joinpath(logdir(depot), "scratch_usage.toml")) do filename, info
            # For Artifact usage, store only the last DateTime for each filename found
            usage[filename] = max(get(usage, filename, DateTime(0)), DateTime(info["time"]))
            if !haskey(parents, filename)
                parents[filename] = Set{String}()
            end
            for parent in info["parent_projects"]
                push!(parents[filename], parent)
            end
        end
        scratch_usage_by_depot[depot] = usage
        scratch_parents_by_depot[depot] = parents
    end

    # Next, figure out which files are still existent
    all_manifest_tomls = unique(f for (_, files) in manifest_usage_by_depot for f in keys(files))
    all_artifact_tomls = unique(f for (_, files) in artifact_usage_by_depot for f in keys(files))
    all_scratch_dirs = unique(f for (_, dirs) in scratch_usage_by_depot for f in keys(dirs))
    all_scratch_parents = Set{String}()
    for (depot, parents) in scratch_parents_by_depot
        for parent in values(parents)
            union!(all_scratch_parents, parent)
        end
    end

    all_manifest_tomls = Set(filter(Pkg.isfile_nothrow, all_manifest_tomls))
    all_artifact_tomls = Set(filter(Pkg.isfile_nothrow, all_artifact_tomls))
    all_scratch_dirs = Set(filter(Pkg.isdir_nothrow, all_scratch_dirs))
    all_scratch_parents = Set(filter(Pkg.isfile_nothrow, all_scratch_parents))

    # Immediately write these back as condensed toml files
    function write_condensed_toml(f::Function, usage_by_depot, fname)
        for (depot, usage) in usage_by_depot
            # Run through user-provided filter/condenser
            usage = f(depot, usage)

            # Write out the TOML file for this depot
            usage_path = joinpath(logdir(depot), fname)
            if !isempty(usage) || isfile(usage_path)
                open(usage_path, "w") do io
                    TOML.print(io, usage, sorted=true)
                end
            end
        end
    end

    # Write condensed Manifest usage
    write_condensed_toml(manifest_usage_by_depot, "manifest_usage.toml") do depot, usage
        # Keep only manifest usage markers that are still existent
        filter!(((k,v),) -> k in all_manifest_tomls, usage)

        # Expand it back into a dict-of-dicts
        return Dict(k => [Dict("time" => v)] for (k, v) in usage)
    end

    # Write condensed Artifact usage
    write_condensed_toml(artifact_usage_by_depot, "artifact_usage.toml") do depot, usage
        filter!(((k,v),) -> k in all_artifact_tomls, usage)
        return Dict(k => [Dict("time" => v)] for (k, v) in usage)
    end

    # Write condensed scratch space usage
    write_condensed_toml(scratch_usage_by_depot, "scratch_usage.toml") do depot, usage
        # Keep only scratch directories that still exist
        filter!(((k,v),) -> k in all_scratch_dirs, usage)

        # Expand it back into a dict-of-dicts
        expanded_usage = Dict{String,Vector{Dict}}()
        for (k, v) in usage
            # Drop scratch spaces whose parents are all non-existant
            parents = scratch_parents_by_depot[depot][k]
            filter!(p -> p in all_scratch_parents, parents)
            if isempty(parents)
                continue
            end

            expanded_usage[k] = [Dict(
                "time" => v,
                "parent_projects" => collect(parents),
            )]
        end
        return expanded_usage
    end

    function process_manifest_pkgs(path)
        # Read the manifest in
        manifest = try
            read_manifest(path)
        catch e
            @warn "Reading manifest file at $path failed with error" exception = e
            return nothing
        end

        # Collect the locations of every package referred to in this manifest
        pkg_dir(uuid, entry) = Operations.find_installed(entry.name, uuid, entry.tree_hash)
        return [pkg_dir(u, e) for (u, e) in manifest if e.tree_hash !== nothing]
    end

    # TODO: Merge with function above to not read manifest twice?
    function process_manifest_repos(path)
        # Read the manifest in
        manifest = try
            read_manifest(path)
        catch e
            # Do not warn here, assume that `process_manifest_pkgs` has already warned
            return nothing
        end

        # Collect the locations of every repo referred to in this manifest
        return [Types.add_repo_cache_path(e.repo.source) for (u, e) in manifest if e.repo.source !== nothing]
    end

    function process_artifacts_toml(path, packages_to_delete)
        # Not only do we need to check if this file doesn't exist, we also need to check
        # to see if it this artifact is contained within a package that is going to go
        # away.  This places an implicit ordering between marking packages and marking
        # artifacts; the package marking must be done first so that we can ensure that
        # all artifacts that are solely bound within such packages also get reaped.
        if any(startswith(path, package_dir) for package_dir in packages_to_delete)
            return nothing
        end

        artifact_dict = try
            parse_toml(path)
        catch e
            @warn "Reading artifacts file at $path failed with error" exception = e
            return nothing
        end

        artifact_path_list = String[]
        for name in keys(artifact_dict)
            getpaths(meta) = artifact_paths(SHA1(hex2bytes(meta["git-tree-sha1"])))
            if isa(artifact_dict[name], Vector)
                for platform_meta in artifact_dict[name]
                    append!(artifact_path_list, getpaths(platform_meta))
                end
            else
                append!(artifact_path_list, getpaths(artifact_dict[name]))
            end
        end
        return artifact_path_list
    end

    function process_scratchspace(path, packages_to_delete)
        # Find all parents of this path
        parents = String[]

        # It is slightly awkward that we need to reach out to our `*_by_depot`
        # datastructures here; that's because unlike Artifacts and Manifests we're not
        # parsing a TOML file to find paths within it here, we're actually doing the
        # inverse, finding files that point to this directory.
        for (depot, parent_map) in scratch_parents_by_depot
            if haskey(parent_map, path)
                append!(parents, parent_map[path])
            end
        end

        # Look to see if all parents are packages that will be removed, if so, filter
        # this scratchspace out by returning `nothing`
        if all(any(startswith(p, dir) for dir in packages_to_delete) for p in parents)
            return nothing
        end
        return [path]
    end

    # Mark packages/artifacts as active or not by calling the appropriate user function
    function mark(process_func::Function, index_files, ctx::Context; do_print=true, verbose=false, file_str=nothing)
        marked_paths = String[]
        active_index_files = Set{String}()
        for index_file in index_files
            # Check to see if it's still alive
            paths = process_func(index_file)
            if paths !== nothing
                # Mark found paths, and record the index_file for printing
                push!(active_index_files, index_file)
                append!(marked_paths, paths)
            end
        end

        if do_print
            @assert file_str !== nothing
            n = length(active_index_files)
            printpkgstyle(ctx.io, :Active, "$(file_str): $(n) found")
            if verbose
                foreach(active_index_files) do f
                    println(ctx.io, "        $(pathrepr(f))")
                end
            end
        end
        # Return the list of marked paths
        return Set(marked_paths)
    end

    gc_time = now()
    function merge_orphanages!(new_orphanage, paths, deletion_list, old_orphanage = UsageDict())
        for path in paths
            free_time = something(
                get(old_orphanage, path, nothing),
                gc_time,
            )

            # No matter what, store the free time in the new orphanage. This allows
            # something terrible to go wrong while trying to delete the artifact/
            # package and it will still try to be deleted next time.  The only time
            # something is removed from an orphanage is when it didn't exist before
            # we even started the `gc` run.
            new_orphanage[path] = free_time

            # If this path was orphaned long enough ago, add it to the deletion list.
            # Otherwise, we continue to propagate its orphaning date but don't delete
            # it.  It will get cleaned up at some future `gc`, or it will be used
            # again during a future `gc` in which case it will not persist within the
            # orphanage list.
            if gc_time - free_time >= collect_delay
                push!(deletion_list, path)
            end
        end
    end


    # Scan manifests, parse them, read in all UUIDs listed and mark those as active
    # printpkgstyle(ctx.io, :Active, "manifests:")
    packages_to_keep = mark(process_manifest_pkgs, all_manifest_tomls, ctx,
        verbose=verbose, file_str="manifest files")

    # Do an initial scan of our depots to get a preliminary `packages_to_delete`.
    packages_to_delete = String[]
    for depot in depots()
        depot_orphaned_packages = String[]
        packagedir = abspath(depot, "packages")
        if isdir(packagedir)
            for name in readdir(packagedir)
                !isdir(joinpath(packagedir, name)) && continue

                for slug in readdir(joinpath(packagedir, name))
                    pkg_dir = joinpath(packagedir, name, slug)
                    !isdir(pkg_dir) && continue

                    if !(pkg_dir in packages_to_keep)
                        push!(depot_orphaned_packages, pkg_dir)
                    end
                end
            end
        end
        merge_orphanages!(UsageDict(), depot_orphaned_packages, packages_to_delete)
    end


    # Next, do the same for artifacts.  Note that we MUST do this after calculating
    # `packages_to_delete`, as `process_artifacts_toml()` uses it internally to discount
    # `Artifacts.toml` files that will be deleted by the future culling operation.
    # printpkgstyle(ctx.io, :Active, "artifacts:")
    artifacts_to_keep = mark(x -> process_artifacts_toml(x, packages_to_delete),
        all_artifact_tomls, ctx; verbose=verbose, file_str="artifact files")
    repos_to_keep = mark(process_manifest_repos, all_manifest_tomls, ctx; do_print=false)
    # printpkgstyle(ctx.io, :Active, "scratchspaces:")
    spaces_to_keep = mark(x -> process_scratchspace(x, packages_to_delete),
        all_scratch_dirs, ctx; verbose=verbose, file_str="scratchspaces")

    # Collect all orphaned paths (packages, artifacts and repos that are not reachable).  These
    # are implicitly defined in that we walk all packages/artifacts installed, then if
    # they were not marked in the above steps, we reap them.
    packages_to_delete = String[]
    artifacts_to_delete = String[]
    repos_to_delete = String[]
    spaces_to_delete = String[]

    for depot in depots()
        # We track orphaned objects on a per-depot basis, writing out our `orphaned.toml`
        # tracking file immediately, only pushing onto the overall `*_to_delete` lists if
        # the package has been orphaned for at least a period of `collect_delay`
        depot_orphaned_packages = String[]
        depot_orphaned_artifacts = String[]
        depot_orphaned_repos = String[]
        depot_orphaned_scratchspaces = String[]

        packagedir = abspath(depot, "packages")
        if isdir(packagedir)
            for name in readdir(packagedir)
                !isdir(joinpath(packagedir, name)) && continue

                for slug in readdir(joinpath(packagedir, name))
                    pkg_dir = joinpath(packagedir, name, slug)
                    !isdir(pkg_dir) && continue

                    if !(pkg_dir in packages_to_keep)
                        push!(depot_orphaned_packages, pkg_dir)
                    end
                end
            end
        end

        reposdir = abspath(depot, "clones")
        if isdir(reposdir)
            for repo in readdir(reposdir)
                repo_dir = joinpath(reposdir, repo)
                !isdir(repo_dir) && continue
                if !(repo_dir in repos_to_keep)
                    push!(depot_orphaned_repos, repo_dir)
                end
            end
        end

        artifactsdir = abspath(depot, "artifacts")
        if isdir(artifactsdir)
            for hash in readdir(artifactsdir)
                artifact_path = joinpath(artifactsdir, hash)
                !isdir(artifact_path) && continue

                if !(artifact_path in artifacts_to_keep)
                    push!(depot_orphaned_artifacts, artifact_path)
                end
            end
        end

        scratchdir = abspath(depot, "scratchspaces")
        if isdir(scratchdir)
            for uuid in readdir(scratchdir)
                uuid_dir = joinpath(scratchdir, uuid)
                !isdir(uuid_dir) && continue
                for space in readdir(uuid_dir)
                    space_dir = joinpath(uuid_dir, space)
                    !isdir(space_dir) && continue
                    if !(space_dir in spaces_to_keep)
                        push!(depot_orphaned_scratchspaces, space_dir)
                    end
                end
            end
        end

        # Read in this depot's `orphaned.toml` file:
        orphanage_file = joinpath(logdir(depot), "orphaned.toml")
        new_orphanage = UsageDict()
        old_orphanage = try
            TOML.parse(String(read(orphanage_file)))
        catch
            UsageDict()
        end

        # Update the package and artifact lists of things to delete, and
        # create the `new_orphanage` list for this depot.
        merge_orphanages!(new_orphanage, depot_orphaned_packages, packages_to_delete, old_orphanage)
        merge_orphanages!(new_orphanage, depot_orphaned_artifacts, artifacts_to_delete, old_orphanage)
        merge_orphanages!(new_orphanage, depot_orphaned_repos, repos_to_delete, old_orphanage)
        merge_orphanages!(new_orphanage, depot_orphaned_scratchspaces, spaces_to_delete, old_orphanage)

        # Write out the `new_orphanage` for this depot
        if !isempty(new_orphanage) || isfile(orphanage_file)
            mkpath(dirname(orphanage_file))
            open(orphanage_file, "w") do io
                TOML.print(io, new_orphanage, sorted=true)
            end
        end
    end

    # Next, we calculate the space savings we're about to gain!
    pretty_byte_str = (size) -> begin
        bytes, mb = Base.prettyprint_getunits(size, length(Base._mem_units), Int64(1024))
        return @sprintf("%.3f %s", bytes, Base._mem_units[mb])
    end

    function recursive_dir_size(path)
        size = 0
        for (root, dirs, files) in walkdir(path)
            for file in files
                path = joinpath(root, file)
                try
                    size += lstat(path).size
                catch
                    @warn "Failed to calculate size of $path"
                end
            end
        end
        return size
    end

    # Delete paths for unreachable package versions and artifacts, and computing size saved
    function delete_path(path)
        path_size = recursive_dir_size(path)
        try
            Base.Filesystem.prepare_for_deletion(path)
            Base.rm(path; recursive=true, force=true)
        catch e
            @warn("Failed to delete $path", exception=e)
        end
        if verbose
            printpkgstyle(ctx.io, :Deleted, pathrepr(path) * " (" *
                pretty_byte_str(path_size) * ")")
        end
        return path_size
    end

    package_space_freed = 0
    repo_space_freed = 0
    artifact_space_freed = 0
    scratch_space_freed = 0
    for path in packages_to_delete
        package_space_freed += delete_path(path)
    end
    for path in repos_to_delete
        repo_space_freed += delete_path(path)
    end
    for path in artifacts_to_delete
        artifact_space_freed += delete_path(path)
    end
    for path in spaces_to_delete
        scratch_space_freed += delete_path(path)
    end

    # Prune package paths that are now empty
    for depot in depots()
        packagedir = abspath(depot, "packages")
        !isdir(packagedir) && continue

        for name in readdir(packagedir)
            name_path = joinpath(packagedir, name)
            !isdir(name_path) && continue
            !isempty(readdir(name_path)) && continue

            Base.rm(name_path)
        end
    end

    # Prune scratch space UUID folders that are now empty
    for depot in depots()
        scratch_dir = abspath(depot, "scratchspaces")
        !isdir(scratch_dir) && continue

        for uuid in readdir(scratch_dir)
            uuid_dir = joinpath(scratch_dir, uuid)
            !isdir(uuid_dir) && continue
            if isempty(readdir(uuid_dir))
                Base.rm(uuid_dir)
            end
        end
    end

    ndel_pkg = length(packages_to_delete)
    ndel_repo = length(repos_to_delete)
    ndel_art = length(artifacts_to_delete)
    ndel_space = length(spaces_to_delete)

    function print_deleted(ndel, freed, name)
        if ndel <= 0
            return
        end

        s = ndel == 1 ? "" : "s"
        bytes_saved_string = pretty_byte_str(freed)
        printpkgstyle(ctx.io, :Deleted, "$(ndel) $(name)$(s) ($bytes_saved_string)")
    end
    print_deleted(ndel_pkg, package_space_freed, "package installation")
    print_deleted(ndel_repo, repo_space_freed, "repo")
    print_deleted(ndel_art, artifact_space_freed, "artifact installation")
    print_deleted(ndel_space, scratch_space_freed, "scratchspace")

    if ndel_pkg == 0 && ndel_art == 0 && ndel_repo == 0 && ndel_space == 0
        printpkgstyle(ctx.io, :Deleted, "no artifacts, repos, packages or scratchspaces")
    end

    return
end

function build(ctx::Context, pkgs::Vector{PackageSpec}; verbose=false, kwargs...)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

    if isempty(pkgs)
        if ctx.env.pkg !== nothing
            push!(pkgs, ctx.env.pkg)
        else
            for (uuid, entry) in ctx.env.manifest
                push!(pkgs, PackageSpec(entry.name, uuid))
            end
        end
    end
    project_resolve!(ctx.env, pkgs)
    foreach(pkg -> pkg.mode = PKGMODE_MANIFEST, pkgs)
    manifest_resolve!(ctx.env.manifest, pkgs)
    ensure_resolved(ctx.env.manifest, pkgs)
    Operations.build(ctx, pkgs, verbose)
end

function _is_stale(paths::Vector{String}, sourcepath::String)
    for path_to_try in paths
        staledeps = Base.stale_cachefile(sourcepath, path_to_try)
        staledeps === true ? continue : return false
    end
    return true
end

function _auto_precompile(ctx::Context)
    if parse(Int, get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", "1")) == 1
        Pkg.precompile(ctx; internal_call=true)
    end
end

function make_pkgspec(man, uuid)
    pkgent = man[uuid]
    # If we have an unusual situation such as an un-versioned package (like an stdlib that
    # is being overridden) its `version` may be `nothing`.
    pkgver = something(pkgent.version, VersionSpec())
    return PackageSpec(uuid = uuid, name = pkgent.name, version = pkgver, tree_hash = pkgent.tree_hash)
end

precompile(; kwargs...) = precompile(Context(); kwargs...)
function precompile(ctx::Context; internal_call::Bool=false, kwargs...)
    Context!(ctx; kwargs...)
    instantiate(ctx; allow_autoprecomp=false, kwargs...)
    time_start = time_ns()
    num_tasks = parse(Int, get(ENV, "JULIA_NUM_PRECOMPILE_TASKS", string(Sys.CPU_THREADS::Int + 1)))
    parallel_limiter = Base.Semaphore(num_tasks)
    io = ctx.io
    fancyprint = can_fancyprint(io)

    # when manually called, unsuspend all packages that were suspended due to precomp errors
    internal_call ? recall_suspended_packages() : precomp_unsuspend!()

    direct_deps = [
        Base.PkgId(uuid, name)
        for (name, uuid) in ctx.env.project.deps if !Base.in_sysimage(Base.PkgId(uuid, name))
    ]

    man = Pkg.Types.read_manifest(ctx.env.manifest_file)
    deps_pair_or_nothing = Iterators.map(man) do dep
        pkg = Base.PkgId(first(dep), last(dep).name)
        Base.in_sysimage(pkg) && return nothing
        deps = [Base.PkgId(last(x), first(x)) for x in last(dep).deps]
        return pkg => filter!(!Base.in_sysimage, deps)
    end
    depsmap = Dict{Base.PkgId, Vector{Base.PkgId}}(Iterators.filter(!isnothing, deps_pair_or_nothing)) #flat map of each dep and its deps

    if ctx.env.pkg !== nothing && isfile( joinpath( dirname(ctx.env.project_file), "src", ctx.env.pkg.name * ".jl") )
        depsmap[Base.PkgId(ctx.env.pkg.uuid, ctx.env.pkg.name)] = [
            Base.PkgId(last(x), first(x))
            for x in ctx.env.project.deps if !Base.in_sysimage(Base.PkgId(last(x), first(x)))
        ]
        push!(direct_deps, Base.PkgId(ctx.env.pkg.uuid, ctx.env.pkg.name))
    end

    started = Dict{Base.PkgId,Bool}()
    was_processed = Dict{Base.PkgId,Base.Event}()
    was_recompiled = Dict{Base.PkgId,Bool}()
    pkg_specs = PackageSpec[]
    for pkgid in keys(depsmap)
        started[pkgid] = false
        was_processed[pkgid] = Base.Event()
        was_recompiled[pkgid] = false
        if haskey(man, pkgid.uuid)
            push!(pkg_specs, make_pkgspec(man, pkgid.uuid))
        end
    end
    precomp_prune_suspended!(pkg_specs)

    # guarding against circular deps
    circular_deps = Base.PkgId[]
    function in_deps(pkgs, deps, dmap)
        isempty(deps) && return false
        !isempty(intersect(pkgs,deps)) && return true
        return any(dep->in_deps(vcat(pkgs, dep), dmap[dep], dmap), deps)
    end
    for (pkg, deps) in depsmap
        if in_deps([pkg], deps, depsmap)
            push!(circular_deps, pkg)
            notify(was_processed[pkg])
            precomp_suspend!(make_pkgspec(man, pkg.uuid))
            !internal_call && @warn "Circular dependency detected. Precompilation skipped for $pkg"
        end
    end

    pkg_queue = Base.PkgId[]
    failed_deps = Dict{Base.PkgId, String}()
    skipped_deps = Base.PkgId[]
    precomperr_deps = Base.PkgId[] # packages that may succeed after a restart (i.e. loaded packages with no cache file)

    print_lock = stdout isa Base.LibuvStream ? stdout.lock::ReentrantLock : ReentrantLock()
    first_started = Base.Event()
    printloop_should_exit::Bool = !fancyprint # exit print loop immediately if not fancy printing
    interrupted_or_done = Base.Event()

    function color_string(str::String, col::Symbol)
        enable_ansi  = get(Base.text_colors, col, Base.text_colors[:default])
        disable_ansi = get(Base.disable_text_style, col, Base.text_colors[:default])
        return string(enable_ansi, str, disable_ansi)
    end
    ansi_moveup(n::Int) = string("\e[", n, "A")
    ansi_movecol1 = "\e[1G"
    ansi_cleartoend = "\e[0J"
    ansi_enablecursor = "\e[?25h"
    ansi_disablecursor = "\e[?25l"
    n_done::Int = 0
    n_already_precomp::Int = 0

    function handle_interrupt(err)
        notify(interrupted_or_done)
        if err isa InterruptException
            lock(print_lock) do
                println(io, " Interrupted: Exiting precompilation...")
            end
        else
            @error "Pkg.precompile error" exception=(err, catch_backtrace())
        end
    end

    t_print = @async begin # fancy print loop
        try
            wait(first_started)
            (isempty(pkg_queue) || interrupted_or_done.set) && return
            fancyprint && lock(print_lock) do
                printpkgstyle(io, :Precompiling, "project...")
                print(io, ansi_disablecursor)
            end
            t = Timer(0; interval=1/10)
            anim_chars = ["◐","◓","◑","◒"]
            i = 1
            last_length = 0
            bar = MiniProgressBar(; indent=2, header = "Progress", color = Base.info_color(), percentage=false, always_reprint=true)
            n_total = length(depsmap)
            bar.max = n_total - n_already_precomp
            final_loop = false
            while !printloop_should_exit
                lock(print_lock) do
                    term_size = Base.displaysize(stdout)::Tuple{Int,Int}
                    num_deps_show = term_size[1] - 3
                    pkg_queue_show = if !interrupted_or_done.set && length(pkg_queue) > num_deps_show
                        last(pkg_queue, num_deps_show)
                    else
                        pkg_queue
                    end
                    str = ""
                    if i > 1
                        str *= string(ansi_moveup(last_length+1), ansi_movecol1, ansi_cleartoend)
                    end
                    bar.current = n_done - n_already_precomp
                    bar.max = n_total - n_already_precomp
                    str *= sprint(io -> show_progress(io, bar); context=io) * '\n'
                    for dep in pkg_queue_show
                        name = dep in direct_deps ? dep.name : string(color_string(dep.name, :light_black))
                        if dep in precomperr_deps
                            str *= string(color_string("  ? ", Base.warn_color()), name, "\n")
                        elseif haskey(failed_deps, dep)
                            str *= string(color_string("  ✗ ", Base.error_color()), name, "\n")
                        elseif was_recompiled[dep]
                            interrupted_or_done.set && continue
                            str *= string(color_string("  ✓ ", :green), name, "\n")
                            @async begin # keep successful deps visible for short period
                                sleep(1);
                                filter!(!isequal(dep), pkg_queue)
                            end
                        elseif started[dep]
                            # Offset each spinner animation using the first character in the package name as the seed.
                            # If not offset, on larger terminal fonts it looks odd that they all sync-up
                            anim_char = anim_chars[(i + Int(dep.name[1])) % length(anim_chars) + 1]
                            anim_char_colored = dep in direct_deps ? anim_char : color_string(anim_char, :light_black)
                            str *= string("  $anim_char_colored ", name, "\n")
                        else
                            str *= "    " * name * "\n"
                        end
                    end
                    last_length = length(pkg_queue_show)
                    print(io, str)
                end
                printloop_should_exit = interrupted_or_done.set && final_loop
                final_loop = interrupted_or_done.set # ensures one more loop to tidy last task after finish
                i += 1
                wait(t)
            end
        catch err
            handle_interrupt(err)
        finally
            fancyprint && print(io, ansi_enablecursor)
        end
    end
    tasks = Task[]
    for (pkg, deps) in depsmap # precompilation loop
        paths = Base.find_all_in_cache_path(pkg)
        sourcepath = Base.locate_package(pkg)
        sourcepath === nothing && continue
        # Heuristic for when precompilation is disabled
        if occursin(r"\b__precompile__\(\s*false\s*\)", read(sourcepath, String))
            notify(was_processed[pkg])
            continue
        end

        task = @async begin
            try
                for dep in deps # wait for deps to finish
                    wait(was_processed[dep])
                end

                suspended = if haskey(man, pkg.uuid) # to handle the working environment uuid
                    precomp_suspended(make_pkgspec(man, pkg.uuid))
                else
                    false
                end
                # skip stale checking and force compilation if any dep was recompiled in this session
                any_dep_recompiled = any(map(dep->was_recompiled[dep], deps))
                is_stale = true
                if (any_dep_recompiled || (!suspended && (is_stale = _is_stale(paths, sourcepath))))
                    Base.acquire(parallel_limiter)
                    is_direct_dep = pkg in direct_deps
                    iob = IOBuffer()
                    name = is_direct_dep ? pkg.name : string(color_string(pkg.name, :light_black))
                    !fancyprint && lock(print_lock) do
                        isempty(pkg_queue) && printpkgstyle(io, :Precompiling, "project...")
                    end
                    push!(pkg_queue, pkg)
                    started[pkg] = true
                    fancyprint && notify(first_started)
                    if interrupted_or_done.set
                        notify(was_processed[pkg])
                        Base.release(parallel_limiter)
                        return
                    end
                    try
                        ret = Logging.with_logger(Logging.NullLogger()) do
                            Base.compilecache(pkg, sourcepath, iob, devnull) # capture stderr, send stdout to devnull
                        end
                        if ret isa Base.PrecompilableError
                            push!(precomperr_deps, pkg)
                            !fancyprint && lock(print_lock) do
                                println(io, string(color_string("  ? ", Base.warn_color()), name))
                            end
                        else
                            !fancyprint && lock(print_lock) do
                                println(io, string(color_string("  ✓ ", :green), name))
                            end
                            was_recompiled[pkg] = true
                        end
                    catch err
                        if err isa ErrorException
                            failed_deps[pkg] = is_direct_dep ? String(take!(iob)) : ""
                            !fancyprint && lock(print_lock) do
                                println(io, string(color_string("  ✗ ", Base.error_color()), name))
                            end
                            if haskey(man, pkg.uuid)
                                precomp_suspend!(make_pkgspec(man, pkg.uuid))
                            end
                        else
                            rethrow(err)
                        end
                    finally
                        Base.release(parallel_limiter)
                    end
                else
                    !is_stale && (n_already_precomp += 1)
                    suspended && !in(pkg, circular_deps) && push!(skipped_deps, pkg)
                end
                n_done += 1
                notify(was_processed[pkg])
            catch err_outer
                handle_interrupt(err_outer)
                notify(was_processed[pkg])
            finally
                filter!(!istaskdone, tasks)
                length(tasks) == 1 && notify(interrupted_or_done)
            end
        end
        push!(tasks, task)
    end
    isempty(tasks) && notify(interrupted_or_done)
    try
        wait(interrupted_or_done)
    catch err
        handle_interrupt(err)
    end
    notify(first_started) # in cases of no-op or !fancyprint
    save_suspended_packages() # save list to scratch space
    wait(t_print)
    !all(istaskdone, tasks) && return # if some not finished, must have errored or been interrupted
    seconds_elapsed = round(Int, (time_ns() - time_start) / 1e9)
    ndeps = count(values(was_recompiled))
    if ndeps > 0 || !isempty(failed_deps)
        plural = ndeps == 1 ? "y" : "ies"
        str = "$(ndeps) dependenc$(plural) successfully precompiled in $(seconds_elapsed) seconds"
        if n_already_precomp > 0 || !isempty(skipped_deps)
            str *= " ("
            n_already_precomp > 0 && (str *= "$n_already_precomp already precompiled")
            !isempty(circular_deps) && (str *= ", $(length(circular_deps)) skipped due to circular dependency")
            !isempty(skipped_deps) && (str *= ", $(length(skipped_deps)) skipped during auto due to previous errors")
            str *= ")"
        end
        if !isempty(precomperr_deps)
            plural = length(precomperr_deps) == 1 ? "y" : "ies"
            str *= string("\n",
                color_string(string(length(precomperr_deps)), Base.warn_color()),
                " dependenc$(plural) failed but may be precompilable after restarting julia"
            )
        end
        if internal_call && !isempty(failed_deps)
            plural = length(failed_deps) == 1 ? "y" : "ies"
            str *= "\n" * color_string("$(length(failed_deps))", Base.error_color()) * " dependenc$(plural) errored"
        end
        lock(print_lock) do
            println(io, str)
        end
        if !internal_call
            err_str = ""
            n_direct_errs = 0
            for (dep, err) in failed_deps
                if dep in direct_deps
                    err_str *= "\n" * "$dep" * "\n\n" * err * (n_direct_errs > 0 ? "\n" : "")
                    n_direct_errs += 1
                end
            end
            if err_str != ""
                println(io, "")
                plural = n_direct_errs == 1 ? "y" : "ies"
                pkgerror("The following $( n_direct_errs) direct dependenc$(plural) failed to precompile:\n$(err_str[1:end-1])")
            end
        end
    end
    nothing
end

const pkgs_precompile_suspended = PackageSpec[]
function save_suspended_packages()
    path = Operations.pkg_scratchpath()
    fpath = joinpath(path, string("suspend_cache_", hash(Base.active_project() * string(Base.VERSION))))
    mkpath(path); Base.Filesystem.rm(fpath, force=true)
    open(fpath, "w") do io
        serialize(io, pkgs_precompile_suspended)
    end
    return nothing
end
function recall_suspended_packages()
    fpath = joinpath(Operations.pkg_scratchpath(), string("suspend_cache_", hash(Base.active_project() * string(Base.VERSION))))
    if isfile(fpath)
        v = open(fpath) do io
            try
                deserialize(io)
            catch
                PackageSpec[]
            end
        end
        append!(empty!(pkgs_precompile_suspended), v)
    else
        empty!(pkgs_precompile_suspended)
    end
    return nothing
end
precomp_suspend!(pkg::PackageSpec) = push!(pkgs_precompile_suspended, pkg)
precomp_unsuspend!() = empty!(pkgs_precompile_suspended)
precomp_suspended(pkg::PackageSpec) = pkg in pkgs_precompile_suspended
precomp_prune_suspended!(pkgs::Vector{PackageSpec}) = filter!(in(pkgs), pkgs_precompile_suspended)

function tree_hash(repo::LibGit2.GitRepo, tree_hash::String)
    try
        return LibGit2.GitObject(repo, tree_hash)
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    return nothing
end

instantiate(; kwargs...) = instantiate(Context(); kwargs...)
function instantiate(ctx::Context; manifest::Union{Bool, Nothing}=nothing,
                     update_registry::Bool=true, verbose::Bool=false,
                     platform::AbstractPlatform=HostPlatform(), allow_autoprecomp::Bool=true, kwargs...)
    Context!(ctx; kwargs...)
    if Registry.download_default_registries(ctx.io)
        copy!(ctx.registries, Registry.reachable_registries())
    end
    if !isfile(ctx.env.project_file) && isfile(ctx.env.manifest_file)
        _manifest = Pkg.Types.read_manifest(ctx.env.manifest_file)
        deps = Dict{String,String}()
        for (uuid, pkg) in _manifest
            if pkg.name in keys(deps)
                # TODO, query what package to put in Project when in interactive mode?
                pkgerror("cannot instantiate a manifest without project file when the manifest has multiple packages with the same name ($(pkg.name))")
            end
            deps[pkg.name] = string(uuid)
        end
        Types.write_project(Dict("deps" => deps), ctx.env.project_file)
        return instantiate(Context(); manifest=manifest, update_registry=update_registry, verbose=verbose, kwargs...)
    end
    if (!isfile(ctx.env.manifest_file) && manifest === nothing) || manifest == false
        up(ctx; update_registry=update_registry)
        return
    end
    if !isfile(ctx.env.manifest_file) && manifest == true
        pkgerror("expected manifest file at `$(ctx.env.manifest_file)` but it does not exist")
    end
    Operations.prune_manifest(ctx.env)
    for (name, uuid) in ctx.env.project.deps
        get(ctx.env.manifest, uuid, nothing) === nothing || continue
        pkgerror("`$name` is a direct dependency, but does not appear in the manifest.",
                 " If you intend `$name` to be a direct dependency, run `Pkg.resolve()` to populate the manifest.",
                 " Otherwise, remove `$name` with `Pkg.rm(\"$name\")`.",
                 " Finally, run `Pkg.instantiate()` again.")
    end
    # TODO: seems to be a bug in is_instantiated on the line below so we have to download
    # artifacts here even though we do the same at the end of this function
    Operations.download_artifacts([dirname(ctx.env.manifest_file)]; platform=platform, verbose=verbose)
    # check if all source code and artifacts are downloaded to exit early
    if Operations.is_instantiated(ctx.env)
        allow_autoprecomp && _auto_precompile(ctx)
        return
    end

    pkgs = Operations.load_all_deps(ctx.env)
    try
        # First try without updating the registry
        Operations.check_registered(ctx.registries, pkgs)
    catch e
        if !(e isa PkgError) || update_registry == false
            rethrow(e)
        end
        Registry.update(; io=ctx.io, force=false)
        Operations.check_registered(ctx.registries, pkgs)
    end
    new_git = UUID[]
    # Handling packages tracking repos
    for pkg in pkgs
        pkg.repo.source !== nothing || continue
        sourcepath = Operations.source_path(ctx.env.project_file, pkg)
        isdir(sourcepath) && continue
        ## Download repo at tree hash
        # determine canonical form of repo source
        if isurl(pkg.repo.source)
            repo_source = pkg.repo.source
        else
            repo_source = normpath(joinpath(dirname(ctx.env.project_file), pkg.repo.source))
        end
        if !isurl(repo_source) && !isdir(repo_source)
            pkgerror("Did not find path `$(repo_source)` for $(err_rep(pkg))")
        end
        repo_path = Types.add_repo_cache_path(repo_source)
        LibGit2.with(GitTools.ensure_clone(ctx.io, repo_path, repo_source; isbare=true)) do repo
            # We only update the clone if the tree hash can't be found
            tree_hash_object = tree_hash(repo, string(pkg.tree_hash))
            if tree_hash_object === nothing
                GitTools.fetch(ctx.io, repo, repo_source; refspecs=Types.refspecs)
                tree_hash_object = tree_hash(repo, string(pkg.tree_hash))
            end
            if tree_hash_object === nothing
                 pkgerror("Did not find tree_hash $(pkg.tree_hash) for $(err_rep(pkg))")
            end
            mkpath(sourcepath)
            GitTools.checkout_tree_to_path(repo, tree_hash_object, sourcepath)
            push!(new_git, pkg.uuid)
        end
    end

    # Install all packages
    new_apply = Operations.download_source(ctx, pkgs)
    # Install all artifacts
    Operations.download_artifacts(ctx.env, pkgs; platform=platform, verbose=verbose)
    # Run build scripts
    Operations.build_versions(ctx, union(UUID[pkg.uuid for pkg in new_apply], new_git); verbose=verbose)

    allow_autoprecomp && _auto_precompile(ctx; kwargs...)
end


@deprecate status(mode::PackageMode) status(mode=mode)

function status(ctx::Context, pkgs::Vector{PackageSpec}; diff::Bool=false, mode=PKGMODE_PROJECT,
                io::IO=stdout, kwargs...)
    Context!(ctx; io=io, kwargs...)
    Operations.status(ctx, pkgs, mode=mode, git_diff=diff)
    return nothing
end


function activate(;temp=false,shared=false)
    shared && pkgerror("Must give a name for a shared environment")
    temp && return activate(mktempdir())
    Base.ACTIVE_PROJECT[] = nothing
    p = Base.active_project()
    p === nothing || printpkgstyle(DEFAULT_IO[], :Activating, "environment at $(pathrepr(p))")
    add_snapshot_to_undo()
    return nothing
end
function _activate_dep(dep_name::AbstractString)
    Base.active_project() === nothing && return
    ctx = nothing
    try
        ctx = Context()
    catch err
        err isa PkgError || rethrow()
        return
    end
    uuid = get(ctx.env.project.deps, dep_name, nothing)
    if uuid !== nothing
        entry = manifest_info(ctx.env.manifest, uuid)
        if entry.path !== nothing
            return joinpath(dirname(ctx.env.project_file), entry.path)
        end
    end
end
function activate(path::AbstractString; shared::Bool=false, temp::Bool=false)
    temp && pkgerror("Can not give `path` argument when creating a temporary environment")
    if !shared
        # `pkg> activate path`/`Pkg.activate(path)` does the following
        # 1. if path exists, activate that
        # 2. if path exists in deps, and the dep is deved, activate that path (`devpath` above)
        # 3. activate the non-existing directory (e.g. as in `pkg> activate .` for initing a new env)
        if Pkg.isdir_nothrow(path)
            fullpath = abspath(path)
        else
            fullpath = _activate_dep(path)
            if fullpath === nothing
                fullpath = abspath(path)
            end
        end
    else
        # initialize `fullpath` in case of empty `Pkg.depots()`
        fullpath = ""
        # loop over all depots to check if the shared environment already exists
        for depot in Pkg.depots()
            fullpath = joinpath(Pkg.envdir(depot), path)
            isdir(fullpath) && break
        end
        # this disallows names such as "Foo/bar", ".", "..", etc
        if basename(abspath(fullpath)) != path
            pkgerror("not a valid name for a shared environment: $(path)")
        end
        # unless the shared environment already exists, place it in the first depots
        if !isdir(fullpath)
            fullpath = joinpath(Pkg.envdir(Pkg.depots1()), path)
        end
    end
    Base.ACTIVE_PROJECT[] = Base.load_path_expand(fullpath)
    p = Base.active_project()
    if p !== nothing
        n = ispath(p) ? "" : "new "
        printpkgstyle(DEFAULT_IO[], :Activating, "$(n)environment at $(pathrepr(p))")
    end
    add_snapshot_to_undo()
    return nothing
end
function activate(f::Function, new_project::AbstractString)
    old = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = new_project
    try
        f()
    finally
        Base.ACTIVE_PROJECT[] = old
    end
end

########
# Undo #
########

struct UndoSnapshot
    date::DateTime
    project::Types.Project
    manifest::Types.Manifest
end
mutable struct UndoState
    idx::Int
    entries::Vector{UndoSnapshot}
end
UndoState() = UndoState(0, UndoState[])
const undo_entries = Dict{String, UndoState}()
const max_undo_limit = 50
const saved_initial_snapshot = Ref(false)

function add_snapshot_to_undo(env=nothing)
    # only attempt to take a snapshot if there is
    # an active project to be found
    if env === nothing
        if Base.active_project() === nothing
            return
        else
            env = EnvCache()
        end
    end
    state = get!(undo_entries, env.project_file) do
        UndoState()
    end
    # Is the current state the same as the previous one, do nothing
    if !isempty(state.entries) && env.project == env.original_project && env.manifest == env.original_manifest
        return
    end
    snapshot = UndoSnapshot(now(), env.project, env.manifest)
    deleteat!(state.entries, 1:(state.idx-1))
    pushfirst!(state.entries, snapshot)
    state.idx = 1

    resize!(state.entries, min(length(state.entries), max_undo_limit))
end

undo(ctx = Context()) = redo_undo(ctx, :undo,  1)
redo(ctx = Context()) = redo_undo(ctx, :redo, -1)
function redo_undo(ctx, mode::Symbol, direction::Int)
    @assert direction == 1 || direction == -1
    state = get(undo_entries, ctx.env.project_file, nothing)
    state === nothing && pkgerror("no undo state for current project")
    state.idx == (mode === :redo ? 1 : length(state.entries)) && pkgerror("$mode: no more states left")

    state.idx += direction
    snapshot = state.entries[state.idx]
    ctx.env.manifest, ctx.env.project = snapshot.manifest, snapshot.project
    write_env(ctx.env; update_undo=false)
    Operations.show_update(ctx)
end


function setprotocol!(;
    domain::AbstractString="github.com",
    protocol::Union{Nothing, AbstractString}=nothing
)
    GitTools.setprotocol!(domain=domain, protocol=protocol)
    return nothing
end

@deprecate setprotocol!(proto::Union{Nothing, AbstractString}) setprotocol!(protocol = proto) false

# API constructor
function Package(;name::Union{Nothing,AbstractString} = nothing,
                 uuid::Union{Nothing,String,UUID} = nothing,
                 version::Union{VersionNumber, String, VersionSpec, Nothing} = nothing,
                 url = nothing, rev = nothing, path=nothing, mode::PackageMode = PKGMODE_PROJECT,
                 subdir = nothing)
    if path !== nothing && url !== nothing
        pkgerror("`path` and `url` are conflicting specifications")
    end
    repo = Types.GitRepo(rev = rev, source = url !== nothing ? url : path, subdir = subdir)
    version = version === nothing ? VersionSpec() : VersionSpec(version)
    uuid = uuid isa String ? UUID(uuid) : uuid
    PackageSpec(;name=name, uuid=uuid, version=version, mode=mode, path=nothing,
                repo=repo, tree_hash=nothing)
end
Package(name::AbstractString) = PackageSpec(name)
Package(name::AbstractString, uuid::UUID) = PackageSpec(name, uuid)
Package(name::AbstractString, uuid::UUID, version::VersionTypes) = PackageSpec(name, uuid, version)

end # module

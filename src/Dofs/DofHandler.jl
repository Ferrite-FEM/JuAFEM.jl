abstract type AbstractDofHandler end

"""
    get_grid(dh::AbstractDofHandler)

Access some grid representation for the dof handler.

!!! note
    This API function is currently not well-defined. It acts as the interface between 
    distributed assembly and assembly on a single process, because most parts of the
    functionality can be handled by only acting on the locally owned cell set.
"""
get_grid(dh::AbstractDofHandler)


struct SubDofHandler{DH} <: AbstractDofHandler
    # From constructor
    dh::DH
    cellset::Set{Int}
    # Populated in add!
    field_names::Vector{Symbol}
    field_interpolations::Vector{Interpolation}
    field_n_components::Vector{Int} # Redundant with interpolations, remove?
    # Computed in close!
    ndofs_per_cell::ScalarWrapper{Int}
    # const dof_ranges::Vector{UnitRange{Int}} # TODO: Why not?
end

# TODO: Should be an inner constructor.
function SubDofHandler(dh::DH, cellset) where {DH <: AbstractDofHandler}
    isclosed(dh) && error("DofHandler already closed")
    # Compute the celltype and make sure all elements have the same one
    CT = getcelltype(dh.grid, first(cellset))
    if any(x -> getcelltype(dh.grid, x) !== CT, cellset)
        error("all cells in a SubDofHandler must be of the same type")
    end
    # Make sure this set is disjoint with all other existing
    for sdh in dh.subdofhandlers
        if !isdisjoint(cellset, sdh.cellset)
            error("cellset not disjoint with sets in existing SubDofHandlers")
        end
    end
    # Construct and insert into the parent dh
    sdh = SubDofHandler{typeof(dh)}(dh, cellset, Symbol[], Interpolation[], Int[], ScalarWrapper(-1))
    push!(dh.subdofhandlers, sdh)
    return sdh
end

@inline getcelltype(sdh::SubDofHandler) = getcelltype(get_grid(sdh.dh), first(sdh.cellset))

function Base.show(io::IO, mime::MIME"text/plain", sdh::SubDofHandler)
    println(io, typeof(sdh))
    println(io, "  Cell type: ", getcelltype(sdh))
    _print_field_information(io, mime, sdh)
end

function _print_field_information(io::IO, mime::MIME"text/plain", sdh::SubDofHandler)
    println(io, "  Fields:")
    for (i, fieldname) in pairs(sdh.field_names)
        println(io, "    ", repr(mime, fieldname), ", ", repr(mime, sdh.field_interpolations[i]))
    end
    if !isclosed(sdh.dh)
        print(io, "  Not closed!")
    else
        println(io, "  Dofs per cell: ", ndofs_per_cell(sdh))
    end
end

"""
    DofHandler(grid::Grid)

Construct a `DofHandler` based on `grid`. Supports:
- `Grid`s with or without concrete element type (E.g. "mixed" grids with several different element types.)
- One or several fields, which can live on the whole domain or on subsets of the `Grid`.
"""
struct DofHandler{dim,G<:AbstractGrid{dim}} <: AbstractDofHandler
    subdofhandlers::Vector{SubDofHandler{DofHandler{dim, G}}}
    field_names::Vector{Symbol}
    # Dofs for cell i are stored in cell_dofs at the range:
    #     cell_dofs_offset[i]:(cell_dofs_offset[i]+ndofs_per_cell(dh, i)-1)
    cell_dofs::Vector{Int}
    cell_dofs_offset::Vector{Int}
    cell_to_subdofhandler::Vector{Int} # maps cell id -> SubDofHandler id
    closed::ScalarWrapper{Bool}
    grid::G
    ndofs::ScalarWrapper{Int}
end

function DofHandler(grid::G) where {dim, G <: AbstractGrid{dim}}
    ncells = getncells(grid)
    sdhs = SubDofHandler{DofHandler{dim, G}}[]
    DofHandler{dim, G}(sdhs, Symbol[], Int[], zeros(Int, ncells), zeros(Int, ncells), ScalarWrapper(false), grid, ScalarWrapper(-1))
end

function Base.show(io::IO, mime::MIME"text/plain", dh::DofHandler)
    println(io, typeof(dh))
    if length(dh.subdofhandlers) == 1
        _print_field_information(io, mime, dh.subdofhandlers[1])
    else
        println(io, "  Fields:")
        for fieldname in getfieldnames(dh)
            println(io, "    ", repr(fieldname), ", dim: ", getfielddim(dh, fieldname))
        end
    end
    if !isclosed(dh)
        print(io, "  Not closed!")
    else
        print(io, "  Total dofs: ", ndofs(dh))
    end
end

isclosed(dh::AbstractDofHandler) = dh.closed[]
get_grid(dh::DofHandler) = dh.grid

"""
    ndofs(dh::AbstractDofHandler)

Return the number of degrees of freedom in `dh`
"""
ndofs(dh::AbstractDofHandler) = dh.ndofs[]

"""
    ndofs_per_cell(dh::AbstractDofHandler[, cell::Int=1])

Return the number of degrees of freedom for the cell with index `cell`.

See also [`ndofs`](@ref).
"""
function ndofs_per_cell(dh::DofHandler, cell::Int=1)
    @boundscheck 1 <= cell <= getncells(get_grid(dh))
    return @inbounds ndofs_per_cell(dh.subdofhandlers[dh.cell_to_subdofhandler[cell]])
end
ndofs_per_cell(sdh::SubDofHandler) = sdh.ndofs_per_cell[]
ndofs_per_cell(sdh::SubDofHandler, ::Int) = sdh.ndofs_per_cell[] # for compatibility with DofHandler

"""
    celldofs!(global_dofs::Vector{Int}, dh::AbstractDofHandler, i::Int)

Store the degrees of freedom that belong to cell `i` in `global_dofs`.

See also [`celldofs`](@ref).
"""
function celldofs!(global_dofs::Vector{Int}, dh::DofHandler, i::Int)
    @assert isclosed(dh)
    @assert length(global_dofs) == ndofs_per_cell(dh, i)
    unsafe_copyto!(global_dofs, 1, dh.cell_dofs, dh.cell_dofs_offset[i], length(global_dofs))
    return global_dofs
end
function celldofs!(global_dofs::Vector{Int}, sdh::SubDofHandler, i::Int)
    @assert i in sdh.cellset
    return celldofs!(global_dofs, sdh.dh, i)
end

"""
    celldofs(dh::AbstractDofHandler, i::Int)

Return a vector with the degrees of freedom that belong to cell `i`.

See also [`celldofs!`](@ref).
"""
function celldofs(dh::AbstractDofHandler, i::Int)
    return celldofs!(zeros(Int, ndofs_per_cell(dh, i)), dh, i)
end

function cellnodes!(global_nodes::Vector{Int}, dh::DofHandler, i::Union{Int, <:AbstractCell})
    cellnodes!(global_nodes, get_grid(dh), i)
end

"""
    getfieldnames(dh::DofHandler)
    getfieldnames(sdh::SubDofHandler)

Return a vector with the unique names of all fields. The order is the sam eas the order in
which they were originally added to the (Sub)DofHandler. Can be used as an iterable over all
the fields.
"""
getfieldnames(dh::DofHandler) = dh.field_names
getfieldnames(sdh::SubDofHandler) = sdh.field_names

getfielddim(sdh::SubDofHandler, field_idx::Int) = n_components(sdh.field_interpolations[field_idx])::Int
getfielddim(sdh::SubDofHandler, field_name::Symbol) = getfielddim(sdh, find_field(sdh, field_name))

"""
    getfielddim(dh::DofHandler, field_idxs::NTuple{2,Int})
    getfielddim(dh::DofHandler, field_name::Symbol)
    getfielddim(sdh::SubDofHandler, field_idx::Int)
    getfielddim(sdh::SubDofHandler, field_name::Symbol)

Return the dimension (number of components) of a given field. The field can be specified by
its index (see [`find_field`](@ref)) or its name.
"""
function getfielddim(dh::DofHandler, field_idxs::NTuple{2, Int})
    sdh_idx, field_idx = field_idxs
    fielddim = getfielddim(dh.subdofhandlers[sdh_idx], field_idx)
    return fielddim
end
getfielddim(dh::DofHandler, name::Symbol) = getfielddim(dh, find_field(dh, name))

"""
    add!(sdh::SubDofHandler, name::Symbol, ip::Interpolation)

Add a field called `name` approximated by `ip` to the SubDofHandler `sdh`.
"""
function add!(sdh::SubDofHandler, name::Symbol, ip::Interpolation)
    @assert !isclosed(sdh.dh)
    # Verify that name doesn't exist
    if name in sdh.field_names
        error("field already exist")
    end
    # Verify that fields with the same name in other SubDofHandler have compatible
    # interpolation
    for _sdh in sdh.dh.subdofhandlers
        for (_name, _ip) in zip(_sdh.field_names, _sdh.field_interpolations)
            _name != name && continue
            # same field name, check for same field dimension
            if n_components(ip) != n_components(_ip)
                error("Field :$name has a different number of components in another SubDofHandler. Use a different field name.")
            end
            if getorder(ip) != getorder(_ip)
                @warn "Field :$name uses a different interpolation order in another SubDofHandler."
            end
            # TODO: warn if interpolation type is not the same?
        end
    end
    
    # Check that interpolation is compatible with cells it it added to
    refshape_sdh = getrefshape(getcells(sdh.dh.grid, first(sdh.cellset)))
    if refshape_sdh !== getrefshape(ip)
        error("The refshape of the interpolation $(getrefshape(ip)) is incompatible with the refshape $refshape_sdh of the cells.")
    end

    # Store in the SubDofHandler, it is collected to the parent DofHandler in close!.
    push!(sdh.field_names, name)
    push!(sdh.field_interpolations, ip)
    return sdh
end

"""
    add!(dh::DofHandler, name::Symbol, ip::Interpolation)

Add a field called `name` approximated by `ip` to the DofHandler `dh`.

The field is added to all cells of the underlying grid, use
[`SubDofHandler`](@ref)s if the grid contains multiple cell types, or to add
the field to subset of all the cells.
"""
function add!(dh::DofHandler, name::Symbol, ip::Interpolation)
    @assert !isclosed(dh)
    celltype = getcelltype(get_grid(dh))
    @assert isconcretetype(celltype)
    if isempty(dh.subdofhandlers)
        # Create a new SubDofHandler for all cells
        sdh = SubDofHandler(dh, Set(1:getncells(get_grid(dh))))
    elseif length(dh.subdofhandlers) == 1
        # Add to existing SubDofHandler (if it covers all cells)
        sdh = dh.subdofhandlers[1]
        if length(sdh.cellset) != getncells(get_grid(dh))
            error("can not add field to DofHandler with a SubDofHandler for a subregion")
        end
    else # length(dh.subdofhandlers) > 1
        error("can not add field to DofHandler with multiple SubDofHandlers")
    end
    # Add to SubDofHandler
    add!(sdh, name, ip)
    return dh
end

"""
    close!(dh::AbstractDofHandler)

Closes `dh` and creates degrees of freedom for each cell.
"""
function close!(dh::DofHandler)
    dh, _, _, _ = __close!(dh)
    return dh
end

"""
    __close!(dh::DofHandler)

Internal entry point for dof distribution.

Dofs are distributed as follows:
For the `DofHandler` each `SubDofHandler` is visited in the order they were added.
For each field in the `SubDofHandler` create dofs for the cell.
This means that dofs on a particular cell will be numbered in groups for each field,
so first the dofs for field 1 are distributed, then field 2, etc.
For each cell dofs are first distributed on its vertices, then on the interior of edges (if applicable), then on the 
interior of faces (if applicable), and finally on the cell interior.
The entity ordering follows the geometrical ordering found in [`vertices`](@ref), [`faces`](@ref) and [`edges`](@ref).
"""
function __close!(dh::DofHandler{dim}) where {dim}
    @assert !isclosed(dh)

    # Collect the global field names
    empty!(dh.field_names)
    for sdh in dh.subdofhandlers, name in sdh.field_names
        name in dh.field_names || push!(dh.field_names, name)
    end
    numfields = length(dh.field_names)

    # NOTE: Maybe it makes sense to store *Index in the dicts instead.

    # `vertexdict` keeps track of the visited vertices. The first dof added to vertex v is
    # stored in vertexdict[v].
    # TODO: No need to allocate this vector for fields that don't have vertex dofs
    vertexdicts = [zeros(Int, getnnodes(get_grid(dh))) for _ in 1:numfields]

    # `edgedict` keeps track of the visited edges, this will only be used for a 3D problem.
    # An edge is uniquely determined by two global vertices, with global direction going
    # from low to high vertex number.
    edgedicts = [Dict{Tuple{Int,Int}, Tuple{UnitRange{Int}, PathOrientationInfo}}() for _ in 1:numfields]

    # `facedict` keeps track of the visited faces. We only need to store the first dof we
    # add to the face since currently more dofs per face isn't supported. In
    # 2D a face (i.e. a line) is uniquely determined by 2 vertices, and in 3D a face (i.e. a
    # surface) is uniquely determined by 3 vertices.
    facedicts = [Dict{NTuple{dim,Int}, Tuple{UnitRange{Int}, PathOrientationInfo}}() for _ in 1:numfields]

    # Set initial values
    nextdof = 1  # next free dof to distribute

    @debug println("\n\nCreating dofs\n")
    for (sdhi, sdh) in pairs(dh.subdofhandlers)
        nextdof = _close_subdofhandler!(
            dh,
            sdh,
            sdhi, # TODO: Store in the SubDofHandler?
            nextdof,
            vertexdicts,
            edgedicts,
            facedicts,
        )
    end
    dh.ndofs[] = maximum(dh.cell_dofs; init=0)
    dh.closed[] = true

    return dh, vertexdicts, edgedicts, facedicts

end

function subtract_dofs!(dst::Vector{Int}, shared_dofs::Vector{Int}, bshared_dofs::Vector{Int}, last_field_offset::Int)
    for i in last_field_offset: length(dst)
        dst[i] ∈ shared_dofs || (dst[i] -=  count(x -> dst[i] > x, bshared_dofs))
    end
end

function subtract_dofs!(dst::Vector{Int}, shared_dofs::Vector{Int}, bshared_dofs::Vector{Int}, dofs)
    for i in dofs
        dst[i] ∈ shared_dofs || (dst[i] -=  count(x -> dst[i] > x, bshared_dofs))
    end
end

"""
    _close_subdofhandler!(dh::DofHandler{sdim}, sdh::SubDofHandler, sdh_index::Int, nextdof::Int, vertexdicts, edgedicts, facedicts) where {sdim}

Main entry point to distribute dofs for a single [`SubDofHandler`](@ref) on its subdomain.
"""
function _close_subdofhandler!(dh::DofHandler{sdim}, sdh::SubDofHandler, sdh_index::Int, nextdof::Int, vertexdicts, edgedicts, facedicts) where {sdim}
    ip_infos = InterpolationInfo[]
    entity_dofs = Vector{Vector{Vector{Int}}}[]
    for interpolation in sdh.field_interpolations
        ip_info = InterpolationInfo(interpolation)
        push!(ip_infos, ip_info)
        ip = interpolation isa VectorizedInterpolation ? interpolation.ip : interpolation
        vdofs = collect(collect.(vertexdof_indices(ip)))
        fdofs = (ip_info.reference_dim == sdim && sdim > 1) ? collect(collect.(facedof_interior_indices(ip))) : Vector{Int}[]
        edofs = sdim > 2 ? collect(collect.(
            ip_info.reference_dim == 3 ? edgedof_interior_indices(ip) : 
            facedof_interior_indices(ip))) : Vector{Int}[]
        cdofs = [collect(celldof_interior_indices(ip))]
        push!(entity_dofs, [vdofs, fdofs, edofs, cdofs])
        # TODO: More than one face dof per face in 3D are not implemented yet. This requires
        #       keeping track of the relative rotation between the faces, not just the
        #       direction as for faces (i.e. edges) in 2D.
    end

    # TODO: Given the InterpolationInfo it should be possible to compute ndofs_per_cell, but
    # doesn't quite work for embedded elements right now (they don't distribute all dofs
    # "promised" by InterpolationInfo). Instead we compute it based on the number of dofs
    # added for the first cell in the set.
    first_cell = true
    ndofs_per_cell = -1
    shared_dofs = (Int[], Int[])
    last_field_offset = nextdof
    # Mapping between the local field index and the global field index
    global_fidxs = Int[findfirst(gname -> gname === lname, dh.field_names) for lname in sdh.field_names]

    # loop over all the cells, and distribute dofs for all the fields
    # TODO: Remove BitSet construction when SubDofHandler ensures sorted collections
    for ci in BitSet(sdh.cellset)
        @debug println("Creating dofs for cell #$ci")

        # TODO: _check_cellset_intersections can be removed in favor of this assertion
        @assert dh.cell_to_subdofhandler[ci] == 0
        dh.cell_to_subdofhandler[ci] = sdh_index

        cell = getcells(get_grid(dh), ci)
        len_cell_dofs_start = length(dh.cell_dofs)
        dh.cell_dofs_offset[ci] = len_cell_dofs_start + 1

        # Distribute dofs per field
        for (lidx, gidx) in pairs(global_fidxs)
            @debug println("\tfield: $(sdh.field_names[lidx])")
            empty!.(shared_dofs)
            sizehint!(facedicts[gidx], length(sdh.cellset) * count(x -> x!=0, ip_infos[lidx].nfacedofs))
            nextdof = _distribute_dofs_for_cell!(
                dh,
                cell,
                ip_infos[lidx],
                nextdof,
                vertexdicts[gidx],
                edgedicts[gidx],
                facedicts[gidx],
                nextdof - 1,
                entity_dofs[lidx],
                shared_dofs,
            )
            subtract_dofs!(dh.cell_dofs, shared_dofs[1], shared_dofs[2], last_field_offset)
            subtract_dofs!(vertexdicts[gidx], shared_dofs[1], shared_dofs[2], vertices(cell))
            last_field_offset = nextdof
        end

        if first_cell
            ndofs_per_cell = length(dh.cell_dofs) - len_cell_dofs_start
            sdh.ndofs_per_cell[] = ndofs_per_cell
            first_cell = false
        else
            @assert ndofs_per_cell == length(dh.cell_dofs) - len_cell_dofs_start
        end
        @debug println("\tDofs for cell #$ci:\t$(dh.cell_dofs[(end-ndofs_per_cell+1):end])")
    end # cell loop
    return nextdof
end

"""
    _distribute_dofs_for_cell!(dh::DofHandler{sdim}, cell::AbstractCell, ip_info::InterpolationInfo, nextdof::Int, vertexdict, edgedict, facedict) where {sdim}

Main entry point to distribute dofs for a single cell.
"""
function _distribute_dofs_for_cell!(dh::DofHandler{sdim}, cell::AbstractCell, ip_info::InterpolationInfo, nextdof::Int,
    vertexdict::Vector{Int}, edgedict::Dict{Tuple{Int,Int}, Tuple{UnitRange{Int}, PathOrientationInfo}}, facedict::Dict{NTuple{sdim,Int}, Tuple{UnitRange{Int}, PathOrientationInfo}},
     len_unique_dof_start::Int, entity_dofs::Vector{Vector{Vector{Int}}}, shared_dofs::Tuple{Vector{Int}, Vector{Int}}) where {sdim}

    
    # Distribute dofs for vertices
    nextdof = add_vertex_dofs(
        dh.cell_dofs, cell, vertexdict,
        nextdof, ip_info, shared_dofs,
        len_unique_dof_start, entity_dofs[1]
    )

    # Distribute dofs for edges (only applicable when dim is 3)
    if sdim == 3 && (ip_info.reference_dim == 3 || ip_info.reference_dim == 2)
        nextdof = add_edge_dofs(
            dh.cell_dofs, cell, edgedict,
            nextdof,
            ip_info,
            shared_dofs,
            len_unique_dof_start,
            entity_dofs[3]
        )
    end

    # Distribute dofs for faces. Filter out 2D interpolations in 3D space, since
    # they are added above as edge dofs.
    if ip_info.reference_dim == sdim && sdim > 1
        nextdof = add_face_dofs(
            dh.cell_dofs, cell, facedict,
            nextdof,
            ip_info,
            shared_dofs,
            len_unique_dof_start,
            entity_dofs[2]
        )
    end

    # Distribute internal dofs for cells
    nextdof = add_cell_dofs(
        dh.cell_dofs, nextdof, ip_info,
        len_unique_dof_start,
        entity_dofs[4][]
    )

    return nextdof
end

function add_vertex_dofs(cell_dofs::Vector{Int}, cell::AbstractCell, vertexdict::Vector{Int}, nextdof::Int, ip_info::InterpolationInfo, shared_dofs::Tuple{Vector{Int}, Vector{Int}}, len_unique_dof_start::Int, vertexdofs::Vector{Vector{Int}})
    nvertexdofs = ip_info.nvertexdofs
    n_copies = ip_info.n_copies
    n = len_unique_dof_start
    for (vi, vertex) in pairs(vertices(cell))
        nvertexdofs[vi] > 0 || continue # skip if no dof on this vertex
        @debug println("\t\tvertex #$vertex")
        first_dof = vertexdict[vertex]
        first_dof <= 0 && (vertexdict[vertex] = n + (vertexdofs[vi][1]-1) * n_copies + 1)
        for lvi in 1:nvertexdofs[vi], d in 1:n_copies
            unshared_dof = n + (vertexdofs[vi][lvi]-1) * n_copies + d
            if first_dof > 0 # reuse dof
                # (Re)compute the next dof from first_dof by adding n_copies dofs from the
                # (lvi-1) previous vertex dofs and the (d-1) dofs already distributed for
                # the current vertex dof
                dof = first_dof + (lvi-1)*n_copies + (d-1)
                push!(cell_dofs, dof)
                push!(shared_dofs[1], dof)
                push!(shared_dofs[2], unshared_dof)
            else
                # create dofs
                push!(cell_dofs, unshared_dof)
                nextdof += 1
            end
        end
        @debug println("\t\t\tdofs: $(cell_dofs[(end-nvertexdofs[vi]*n_copies+1):end])")
    end
    return nextdof
end

"""
    get_or_create_dofs!(nextdof::Int, ndofs::Int, n_copies::Int, dict::Dict, key::Tuple)::Tuple{Int64, StepRange{Int64, Int64}}

Returns the next global dof number and an array of dofs. If dofs have already been created
for the object (vertex, face) then simply return those, otherwise create new dofs.
"""
@inline function get_or_create_dofs!(dst::Vector{Int}, nextdof::Int, ndofs::Int, n_copies::Int, dict::Dict, key::Tuple, orientation::PathOrientationInfo, _entity_dofs, shared_dofs::Tuple{Vector{Int}, Vector{Int}}, n)
    token = Base.ht_keyindex2!(dict, key)
    entity_dofs = orientation.regular ? _entity_dofs : reverse(_entity_dofs)
    if token > 0  # vertex, face etc. visited before
        rng = dict.vals[token][1]
        dofs = @view dst[rng]
        rng = (length(dst)+1):(length(dst) + ndofs*n_copies)
        for i in (orientation.regular ? (1:length(entity_dofs)) : (length(entity_dofs):-1:1)), d in 1:n_copies
            push!(dst, dofs[(i-1)*n_copies + d])
            push!(shared_dofs[1], dofs[(i-1)*n_copies + d])
        end
        for dof in entity_dofs, d in 1:n_copies
            push!(shared_dofs[2], n + (dof-1) * n_copies + d)
        end
        @debug println("\t\t\tkey: $key dofs: $(dofs)  (reused dofs)")
    else  # create new dofs
        rng = (length(dst)+1):(length(dst) + ndofs*n_copies)
        Base._setindex!(dict, (rng, orientation), key, -token)
        for dof in entity_dofs, d in 1:n_copies
            push!(dst, n + (dof-1) * n_copies + d)
        end
        @debug println("\t\t\tkey: $key dofs: $dofs")
        nextdof += ndofs*n_copies
    end
    return nextdof
end

function add_face_dofs(cell_dofs::Vector{Int}, cell::AbstractCell, facedict::Dict, nextdof::Int, ip_info::InterpolationInfo, shared_dofs::Tuple{Vector{Int}, Vector{Int}}, len_unique_dof_start::Int, facedofs::Vector{Vector{Int}})
    nfacedofs = ip_info.nfacedofs
   # TODO: adjust_during_distribution = ip_info.adjust_during_distribution 
    n_copies = ip_info.n_copies
    for (fi,face) in pairs(faces(cell))
        nfacedofs[fi] > 0 || continue # skip if no dof on this face
        sface, orientation = sortface(face)
        @debug println("\t\tface #$sface, $orientation")
        nextdof = get_or_create_dofs!(cell_dofs, nextdof, nfacedofs[fi], n_copies, facedict, sface, orientation, facedofs[fi], shared_dofs, len_unique_dof_start)
        @debug println("\t\t\tadjusted dofs: $(cell_dofs[(end - nfacedofs[fi]*n_copies + 1):end])")
    end
    return nextdof
end

function add_edge_dofs(cell_dofs::Vector{Int}, cell::AbstractCell, edgedict::Dict, nextdof::Int, ip_info::InterpolationInfo, shared_dofs::Tuple{Vector{Int}, Vector{Int}},  len_unique_dof_start::Int, edgedofs::Vector{Vector{Int}})
    # Regular 3D element or 2D interpolation embedded in 3D space
    nedgedofs = ip_info.reference_dim == 3 ? ip_info.nedgedofs : ip_info.nfacedofs
    # TODO: adjust_during_distribution = ip_info.adjust_during_distribution
    n_copies = ip_info.n_copies
    for (ei, edge) in pairs(edges(cell))
        if nedgedofs[ei] > 0
            sedge, orientation = sortedge(edge)
            @debug println("\t\tedge #$sedge, $orientation")
            nextdof = get_or_create_dofs!(cell_dofs, nextdof, nedgedofs[ei], n_copies, edgedict, sedge, orientation, edgedofs[ei], shared_dofs, len_unique_dof_start)
            @debug println("\t\t\tadjusted dofs: $(cell_dofs[(end - nedgedofs[ei]*n_copies + 1):end])")
        end
    end
    return nextdof
end

function add_cell_dofs(cell_dofs::CD, nextdof::Int, ip_info::InterpolationInfo, len_unique_dof_start::Int, celldofs::Vector{Int}) where {CD}
    ncelldofs = ip_info.ncelldofs
    n_copies = ip_info.n_copies
    n = len_unique_dof_start
    @debug println("\t\tcelldofs #$nextdof:$(ncelldofs*n_copies-1)")
    for celldof in celldofs, _copy in 1:n_copies
        push!(cell_dofs, n + (celldof - 1)*n_copies + _copy )
    end
    nextdof += ncelldofs*n_copies
    return nextdof
end

"""
    permute_and_push!

For interpolations with more than one interior dof per edge it may be necessary to adjust
the dofs. Since dofs are (initially) enumerated according to the local edge direction there
can be a direction mismatch with the neighboring element. For example, in the following
nodal interpolation example, with three interior dofs on each edge, the initial pass have
distributed dofs 4, 5, 6 according to the local edge directions:

```
+-----------+
|     A     |
+--4--5--6->+    local edge on element A

 ---------->     global edge

+<-6--5--4--+    local edge on element B
|     B     |
+-----------+
```

For most scalar-valued interpolations we can simply compensate for this by reversing the
numbering on all edges that do not match the global edge direction, i.e. for the edge on
element B in the example.

In addition, we also have to preverse the ordering at each dof location.

For more details we refer to Scroggs et al. [Scroggs2022](@cite) as we follow the methodology
described therein.

# References
 - [Scroggs2022](@cite) Scroggs et al. ACM Trans. Math. Softw. 48 (2022).
"""
@inline function permute_and_push!(cell_dofs::Vector{Int}, dofs::StepRange{Int,Int}, orientation::PathOrientationInfo, adjust_during_distribution::Bool)
    # TODO Investigate if we can somehow pass the interpolation into this function in a
    # typestable way.
    n_copies = step(dofs)
    @assert n_copies > 0
    if adjust_during_distribution && !orientation.regular
        # Reverse the dofs for the path
        dofs = reverse(dofs)
    end
    for dof in dofs
        for i in 1:n_copies
            push!(cell_dofs, dof+(i-1))
        end
    end
    return nothing
end

"""
    sortedge(edge::Tuple{Int,Int})

Returns the unique representation of an edge and its orientation.
Here the unique representation is the sorted node index tuple. The
orientation is `true` if the edge is not flipped, where it is `false`
if the edge is flipped.
"""
function sortedge(edge::Tuple{Int,Int})
    a, b = edge
    a < b ? (return (edge, PathOrientationInfo(true))) : (return ((b, a), PathOrientationInfo(false)))
end

"""
sortedge_fast(edge::Tuple{Int,Int})

Returns the unique representation of an edge.
Here the unique representation is the sorted node index tuple.
"""
function sortedge_fast(edge::Tuple{Int,Int})
    a, b = edge
    a < b ? (return edge) : (return (b, a))
end

"""
    sortface(face::Tuple{Int})
    sortface(face::Tuple{Int,Int})
    sortface(face::Tuple{Int,Int,Int})
    sortface(face::Tuple{Int,Int,Int,Int})

Returns the unique representation of a face.
Here the unique representation is the sorted node index tuple.
Note that in 3D we only need indices to uniquely identify a face,
so the unique representation is always a tuple length 3.
"""
sortface(face::Tuple{Int,Int}) = sortedge(face) # Face in 2D is the same as edge in 3D.


"""
    sortface_fast(face::Tuple{Int})
    sortface_fast(face::Tuple{Int,Int})
    sortface_fast(face::Tuple{Int,Int,Int})
    sortface_fast(face::Tuple{Int,Int,Int,Int})

Returns the unique representation of a face.
Here the unique representation is the sorted node index tuple.
Note that in 3D we only need indices to uniquely identify a face,
so the unique representation is always a tuple length 3.
"""
sortface_fast(face::Tuple{Int,Int}) = sortedge_fast(face) # Face in 2D is the same as edge in 3D.

"""
    !!!NOTE TODO implement me.

For more details we refer to [1] as we follow the methodology described therein.

[1] Scroggs, M. W., Dokken, J. S., Richardson, C. N., & Wells, G. N. (2022). 
    Construction of arbitrary order finite element degree-of-freedom maps on 
    polygonal and polyhedral cell meshes. ACM Transactions on Mathematical 
    Software (TOMS), 48(2), 1-23.

    !!!TODO citation via software.

    !!!TODO Investigate if we can somehow pass the interpolation into this function in a typestable way.
"""
@inline function permute_and_push!(cell_dofs::Vector{Int}, dofs::StepRange{Int,Int}, orientation::SurfaceOrientationInfo, adjust_during_distribution::Bool)
    if adjust_during_distribution && length(dofs) > 1
        error("Dof distribution for interpolations with multiple dofs per face not implemented yet.")
    end
    n_copies = step(dofs)
    @assert n_copies > 0
    for dof in dofs
        for i in 1:n_copies
            push!(cell_dofs, dof+(i-1))
        end
    end
    return nothing
end

function sortface(face::Tuple{Int,Int,Int})
    a, b, c = face
    b, c = minmax(b, c)
    a, c = minmax(a, c)
    a, b = minmax(a, b)
    return (a, b, c), PathOrientationInfo(true) # TODO fill struct
end


function sortface_fast(face::Tuple{Int,Int,Int})
    a, b, c = face
    b, c = minmax(b, c)
    a, c = minmax(a, c)
    a, b = minmax(a, b)
    return (a, b, c)
end


function sortface(face::Tuple{Int,Int,Int,Int})
    a, b, c, d = face
    c, d = minmax(c, d)
    b, d = minmax(b, d)
    a, d = minmax(a, d)
    b, c = minmax(b, c)
    a, c = minmax(a, c)
    a, b = minmax(a, b)
    return (a, b, c), PathOrientationInfo(true) # TODO fill struct
end


function sortface_fast(face::Tuple{Int,Int,Int,Int})
    a, b, c, d = face
    c, d = minmax(c, d)
    b, d = minmax(b, d)
    a, d = minmax(a, d)
    b, c = minmax(b, c)
    a, c = minmax(a, c)
    a, b = minmax(a, b)
    return (a, b, c)
end


sortface(face::Tuple{Int}) = face, nothing
sortface_fast(face::Tuple{Int}) = face

"""
    find_field(dh::DofHandler, field_name::Symbol)::NTuple{2,Int}

Return the index of the field with name `field_name` in a `DofHandler`. The index is a
`NTuple{2,Int}`, where the 1st entry is the index of the `SubDofHandler` within which the
field was found and the 2nd entry is the index of the field within the `SubDofHandler`.

!!! note
    Always finds the 1st occurence of a field within `DofHandler`.

See also: [`find_field(sdh::SubDofHandler, field_name::Symbol)`](@ref),
[`_find_field(sdh::SubDofHandler, field_name::Symbol)`](@ref).
"""
function find_field(dh::DofHandler, field_name::Symbol)
    for (sdh_idx, sdh) in pairs(dh.subdofhandlers)
        field_idx = _find_field(sdh, field_name)
        !isnothing(field_idx) && return (sdh_idx, field_idx)
    end
    error("Did not find field :$field_name in DofHandler (existing fields: $(getfieldnames(dh))).")
end

"""
    find_field(sdh::SubDofHandler, field_name::Symbol)::Int

Return the index of the field with name `field_name` in a `SubDofHandler`. Throw an
error if the field is not found.

See also: [`find_field(dh::DofHandler, field_name::Symbol)`](@ref), [`_find_field(sdh::SubDofHandler, field_name::Symbol)`](@ref).
"""
function find_field(sdh::SubDofHandler, field_name::Symbol)
    field_idx = _find_field(sdh, field_name)
    if field_idx === nothing
        error("Did not find field :$field_name in SubDofHandler (existing fields: $(sdh.field_names))")
    end
    return field_idx
end

# No error if field not found
"""
    _find_field(sdh::SubDofHandler, field_name::Symbol)::Int

Return the index of the field with name `field_name` in the `SubDofHandler` `sdh`. Return 
`nothing` if the field is not found.

See also: [`find_field(dh::DofHandler, field_name::Symbol)`](@ref), [`find_field(sdh::SubDofHandler, field_name::Symbol)`](@ref).
"""
function _find_field(sdh::SubDofHandler, field_name::Symbol)
    return findfirst(x -> x === field_name, sdh.field_names)
end

# Calculate the offset to the first local dof of a field
function field_offset(sdh::SubDofHandler, field_idx::Int)
    offset = 0
    for i in 1:(field_idx-1)
        offset += getnbasefunctions(sdh.field_interpolations[i])::Int
    end
    return offset
end

"""
    dof_range(sdh::SubDofHandler, field_idx::Int)
    dof_range(sdh::SubDofHandler, field_name::Symbol)
    dof_range(dh:DofHandler, field_name::Symbol)

Return the local dof range for a given field. The field can be specified by its name or
index, where `field_idx` represents the index of a field within a `SubDofHandler` and
`field_idxs` is a tuple of the `SubDofHandler`-index within the `DofHandler` and the
`field_idx`.

!!! note
    The `dof_range` of a field can vary between different `SubDofHandler`s. Therefore, it is
    advised to use the `field_idxs` or refer to a given `SubDofHandler` directly in case
    several `SubDofHandler`s exist. Using the `field_name` will always refer to the first
    occurence of `field` within the `DofHandler`.

Example:
```jldoctest
julia> grid = generate_grid(Triangle, (3, 3))
Grid{2, Triangle, Float64} with 18 Triangle cells and 16 nodes

julia> dh = DofHandler(grid); add!(dh, :u, 3); add!(dh, :p, 1); close!(dh);

julia> dof_range(dh, :u)
1:9

julia> dof_range(dh, :p)
10:12

julia> dof_range(dh, (1,1)) # field :u
1:9

julia> dof_range(dh.subdofhandlers[1], 2) # field :p
10:12
```
"""
function dof_range(sdh::SubDofHandler, field_idx::Int)
    offset = field_offset(sdh, field_idx)
    field_interpolation = sdh.field_interpolations[field_idx]
    n_field_dofs = getnbasefunctions(field_interpolation)::Int
    return (offset+1):(offset+n_field_dofs)
end
dof_range(sdh::SubDofHandler, field_name::Symbol) = dof_range(sdh, find_field(sdh, field_name))

function dof_range(dh::DofHandler, field_name::Symbol)
    if length(dh.subdofhandlers) > 1
        error("The given DofHandler has $(length(dh.subdofhandlers)) SubDofHandlers. Extracting the dof range based on the fieldname might not be a unique problem in this case. Use `dof_range(sdh::SubDofHandler, field_name)` instead.")
    end
    sdh_idx, field_idx = find_field(dh, field_name)
    return dof_range(dh.subdofhandlers[sdh_idx], field_idx)
end

"""
    getfieldinterpolation(dh::DofHandler, field_idxs::NTuple{2,Int})
    getfieldinterpolation(sdh::SubDofHandler, field_idx::Int)
    getfieldinterpolation(sdh::SubDofHandler, field_name::Symbol)

Return the interpolation of a given field. The field can be specified by its index (see
[`find_field`](@ref) or its name.
"""
function getfieldinterpolation(dh::DofHandler, field_idxs::NTuple{2,Int})
    sdh_idx, field_idx = field_idxs
    ip = dh.subdofhandlers[sdh_idx].field_interpolations[field_idx]
    return ip
end
getfieldinterpolation(sdh::SubDofHandler, field_idx::Int) = sdh.field_interpolations[field_idx]
getfieldinterpolation(sdh::SubDofHandler, field_name::Symbol) = getfieldinterpolation(sdh, find_field(sdh, field_name))

"""
    evaluate_at_grid_nodes(dh::AbstractDofHandler, u::Vector{T}, fieldname::Symbol) where T

Evaluate the approximated solution for field `fieldname` at the node
coordinates of the grid given the Dof handler `dh` and the solution vector `u`.

Return a vector of length `getnnodes(grid)` where entry `i` contains the evalutation of the
approximation in the coordinate of node `i`. If the field does not live on parts of the
grid, the corresponding values for those nodes will be returned as `NaN`s.
"""
function evaluate_at_grid_nodes(dh::DofHandler, u::Vector, fieldname::Symbol)
    return _evaluate_at_grid_nodes(dh, u, fieldname)
end

# Internal method that have the vtk option to allocate the output differently
function _evaluate_at_grid_nodes(dh::DofHandler, u::Vector{T}, fieldname::Symbol, ::Val{vtk}=Val(false)) where {T, vtk}
    # Make sure the field exists
    fieldname ∈ getfieldnames(dh) || error("Field $fieldname not found.")
    # Figure out the return type (scalar or vector)
    field_idx = find_field(dh, fieldname)
    ip = getfieldinterpolation(dh, field_idx)
    RT = ip isa ScalarInterpolation ? T : Vec{n_components(ip),T}
    if vtk
        # VTK output of solution field (or L2 projected scalar data)
        n_c = n_components(ip)
        vtk_dim = n_c == 2 ? 3 : n_c # VTK wants vectors padded to 3D
        data = fill(NaN * zero(T), vtk_dim, getnnodes(get_grid(dh)))
    else
        # Just evalutation at grid nodes
        data = fill(NaN * zero(RT), getnnodes(get_grid(dh)))
    end
    # Loop over the subdofhandlers
    for sdh in dh.subdofhandlers
        # Check if this sdh contains this field, otherwise continue to the next
        field_idx = _find_field(sdh, fieldname)
        field_idx === nothing && continue
        # Set up CellValues with the local node coords as quadrature points
        CT = getcelltype(sdh)
        ip = getfieldinterpolation(sdh, field_idx)
        ip_geo = default_interpolation(CT)
        local_node_coords = reference_coordinates(ip_geo)
        qr = QuadratureRule{getrefshape(ip)}(zeros(length(local_node_coords)), local_node_coords)
        if ip isa VectorizedInterpolation
            # TODO: Remove this hack when embedding works...
            cv = CellValues(qr, ip.ip, ip_geo)
        else
            cv = CellValues(qr, ip, ip_geo)
        end
        drange = dof_range(sdh, field_idx)
        # Function barrier
        _evaluate_at_grid_nodes!(data, sdh, u, cv, drange, RT)
    end
    return data
end

# Loop over the cells and use shape functions to compute the value
function _evaluate_at_grid_nodes!(data::Union{Vector,Matrix}, sdh::SubDofHandler,
        u::Vector{T}, cv::CellValues, drange::UnitRange, ::Type{RT}) where {T, RT}
    ue = zeros(T, length(drange))
    # TODO: Remove this hack when embedding works...
    if RT <: Vec && cv isa CellValues{<:ScalarInterpolation}
        uer = reinterpret(RT, ue)
    else
        uer = ue
    end
    for cell in CellIterator(sdh)
        # Note: We are only using the shape functions: no reinit!(cv, cell) necessary
        @assert getnquadpoints(cv) == length(cell.nodes)
        for (i, I) in pairs(drange)
            ue[i] = u[cell.dofs[I]]
        end
        for (qp, nodeid) in pairs(cell.nodes)
            val = function_value(cv, qp, uer)
            if data isa Matrix # VTK
                data[1:length(val), nodeid] .= val
                data[(length(val)+1):end, nodeid] .= 0 # purge the NaN
            else
                data[nodeid] = val
            end
        end
    end
    return data
end

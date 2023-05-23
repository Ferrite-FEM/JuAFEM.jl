abstract type AbstractDofHandler end

"""
    Field(name::Symbol, interpolation::Interpolation, dim::Int)

Construct `dim`-dimensional `Field` called `name` which is approximated by `interpolation`.

The interpolation is used for distributing the degrees of freedom.
"""
struct Field
    name::Symbol
    interpolation::Interpolation
end

# TODO: Deprecate after DofHandler rework.
function Field(name, interpolation::ScalarInterpolation, dim)
    if dim == 1 # Presumably scalar and not 1D vector
        return Field(name, interpolation)
    else
        return Field(name, VectorizedInterpolation{dim}(interpolation))
    end
end

"""
    FieldHandler(fields::Vector{Field}, cellset::Set{Int})

Construct a `FieldHandler` based on an array of [`Field`](@ref)s and assigns it a set of cells.

A `FieldHandler` must fulfill the following requirements:
- All [`Cell`](@ref)s in `cellset` are of the same type.
- Each field only uses a single interpolation on the `cellset`.
- Each cell belongs only to a single `FieldHandler`, i.e. all fields on a cell must be added within the same `FieldHandler`.

Notice that a `FieldHandler` can hold several fields.
"""
mutable struct FieldHandler
    fields::Vector{Field} # Should not be used, kept for compatibility for now
    field_names::Vector{Symbol}
    field_dims::Vector{Int}
    field_interpolations::Vector{Interpolation}
    cellset::Set{Int}
    ndofs_per_cell::Int # set in close(::DofHandler)
    function FieldHandler(fields, cellset)
        fh = new(fields, Symbol[], Int[], Interpolation[], cellset, -1)
        for f in fields
            push!(fh.field_names, f.name)
            push!(fh.field_dims, n_components(f.interpolation))
            push!(fh.field_interpolations, f.interpolation)
        end
        return fh
    end
end

"""
    DofHandler(grid::Grid)

Construct a `DofHandler` based on `grid`. Supports:
- `Grid`s with or without concrete element type (E.g. "mixed" grids with several different element types.)
- One or several fields, which can live on the whole domain or on subsets of the `Grid`.
"""
struct DofHandler{dim,G<:AbstractGrid{dim}} <: AbstractDofHandler
    fieldhandlers::Vector{FieldHandler}
    field_names::Vector{Symbol}
    # Dofs for cell i are stored in cell_dofs at the range:
    #     cell_dofs_offset[i]:(cell_dofs_offset[i]+ndofs_per_cell(dh, i)-1)
    cell_dofs::Vector{Int}
    cell_dofs_offset::Vector{Int}
    cell_to_fieldhandler::Vector{Int} # maps cell id -> fieldhandler id
    closed::ScalarWrapper{Bool}
    grid::G
    ndofs::ScalarWrapper{Int}
end

function DofHandler(grid::AbstractGrid{dim}) where dim
    ncells = getncells(grid)
    DofHandler{dim,typeof(grid)}(FieldHandler[], Symbol[], Int[], zeros(Int, ncells), zeros(Int, ncells), ScalarWrapper(false), grid, ScalarWrapper(-1))
end

function get_only_sdh_or_error(dh::DofHandler, func::Symbol)
    @assert isclosed(dh)
    if length(dh.fieldhandlers) != 1
        error("$(func) not supported for DofHandler with multiple FieldHandlers")
    end
    return dh.fieldhandlers[1]
end

function MixedDofHandler(::AbstractGrid)
    error("MixedDofHandler is the standard DofHandler in Ferrite now and has been renamed to DofHandler.
Use DofHandler even for mixed grids and fields on subdomains.")
end

function Base.show(io::IO, ::MIME"text/plain", dh::DofHandler)
    println(io, typeof(dh))
    println(io, "  Fields:")
    for fieldname in getfieldnames(dh)
        println(io, "    ", repr(fieldname), ", dim: ", getfielddim(dh, fieldname))
    end
    if !isclosed(dh)
        print(io, "  Not closed!")
    else
        print(io, "  Total dofs: ", ndofs(dh))
    end
end

isclosed(dh::AbstractDofHandler) = dh.closed[]

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
    @boundscheck 1 <= cell <= getncells(dh.grid)
    return @inbounds ndofs_per_cell(dh.fieldhandlers[dh.cell_to_fieldhandler[cell]])
end
ndofs_per_cell(fh::FieldHandler) = fh.ndofs_per_cell
nnodes_per_cell(dh::DofHandler, cell::Int=1) = nnodes_per_cell(dh.grid, cell) # TODO: deprecate, shouldn't belong to DofHandler any longer

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

"""
    celldofs(dh::AbstractDofHandler, i::Int)

Return a vector with the degrees of freedom that belong to cell `i`.

See also [`celldofs!`](@ref).
"""
function celldofs(dh::AbstractDofHandler, i::Int)
    return celldofs!(zeros(Int, ndofs_per_cell(dh, i)), dh, i)
end

#TODO: perspectively remove in favor of `getcoordinates!(global_coords, grid, i)`?
function cellcoords!(global_coords::Vector{Vec{dim,T}}, dh::DofHandler, i::Union{Int, <:AbstractCell}) where {dim,T}
    cellcoords!(global_coords, dh.grid, i)
end

function cellnodes!(global_nodes::Vector{Int}, dh::DofHandler, i::Union{Int, <:AbstractCell})
    cellnodes!(global_nodes, dh.grid, i)
end

"""
    getfieldnames(dh::DofHandler)
    getfieldnames(fh::FieldHandler)

Return a vector with the names of all fields. Can be used as an iterable over all the fields
in the problem.
"""
getfieldnames(dh::DofHandler) = dh.field_names
getfieldnames(fh::FieldHandler) = fh.field_names

getfielddim(fh::FieldHandler, field_idx::Int) = fh.field_dims[field_idx]
getfielddim(fh::FieldHandler, field_name::Symbol) = getfielddim(fh, find_field(fh, field_name))

"""
    getfielddim(dh::DofHandler, field_idxs::NTuple{2,Int})
    getfielddim(dh::DofHandler, field_name::Symbol)
    getfielddim(dh::FieldHandler, field_idx::Int)
    getfielddim(dh::FieldHandler, field_name::Symbol)

Return the dimension of a given field. The field can be specified by its index (see
[`find_field`](@ref)) or its name.
"""
function getfielddim(dh::DofHandler, field_idxs::NTuple{2, Int})
    fh_idx, field_idx = field_idxs
    fielddim = getfielddim(dh.fieldhandlers[fh_idx], field_idx)
    return fielddim
end
getfielddim(dh::DofHandler, name::Symbol) = getfielddim(dh, find_field(dh, name))

"""
    add!(dh::DofHandler, fh::FieldHandler)

Add all fields of the [`FieldHandler`](@ref) `fh` to `dh`.
"""
function add!(dh::DofHandler, fh::FieldHandler)
    # TODO: perhaps check that a field with the same name is the same field?
    @assert !isclosed(dh)
    _check_same_celltype(dh.grid, collect(fh.cellset))
    _check_cellset_intersections(dh, fh)
    # the field interpolations should have the same refshape as the cells they are applied to
    # extract the celltype from the first cell as the celltypes are all equal
    cell_type = typeof(dh.grid.cells[first(fh.cellset)])
    refshape_cellset = getrefshape(default_interpolation(cell_type))
    for interpolation in fh.field_interpolations
        refshape = getrefshape(interpolation)
        refshape_cellset == refshape || error("The RefShapes of the fieldhandlers interpolations must correspond to the RefShape of the cells it is applied to.")
    end

    push!(dh.fieldhandlers, fh)
    return dh
end

function _check_cellset_intersections(dh::DofHandler, fh::FieldHandler)
    for _fh in dh.fieldhandlers
        isdisjoint(_fh.cellset, fh.cellset) || error("Each cell can only belong to a single FieldHandler.")
    end
end

"""
    add!(dh::AbstractDofHandler, name::Symbol, ip::Interpolation)

Add a field called `name` which is approximated by `ip` to `dh`.
The field is added to all cells of the underlying grid. If the grid uses several
celltypes, [`add!(dh::DofHandler, fh::FieldHandler)`](@ref) must be used instead.
"""
function add!(dh::DofHandler, name::Symbol, ip::Interpolation)
    @assert !isclosed(dh)

    celltype = getcelltype(dh.grid)
    @assert isconcretetype(celltype)

    if length(dh.fieldhandlers) == 0
        cellset = Set(1:getncells(dh.grid))
        push!(dh.fieldhandlers, FieldHandler(Field[], cellset))
    elseif length(dh.fieldhandlers) > 1
        error("If you have more than one FieldHandler, you must specify field")
    end
    fh = first(dh.fieldhandlers)

    push!(fh.field_names, name)
    push!(fh.field_dims, n_components(ip))
    push!(fh.field_interpolations, ip)

    field = Field(name, ip)
    push!(fh.fields, field)

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
For the `DofHandler` each `FieldHandler` is visited in the order they were added.
For each field in the `FieldHandler` create dofs for the cell.
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
    for fh in dh.fieldhandlers, name in fh.field_names
        name in dh.field_names || push!(dh.field_names, name)
    end
    numfields = length(dh.field_names)

    # NOTE: Maybe it makes sense to store *Index in the dicts instead.

    # `vertexdict` keeps track of the visited vertices. The first dof added to vertex v is
    # stored in vertexdict[v].
    # TODO: No need to allocate this vector for fields that don't have vertex dofs
    vertexdicts = [zeros(Int, getnnodes(dh.grid)) for _ in 1:numfields]

    # `edgedict` keeps track of the visited edges, this will only be used for a 3D problem.
    # An edge is uniquely determined by two global vertices, with global direction going
    # from low to high vertex number.
    edgedicts = [Dict{Tuple{Int,Int}, Int}() for _ in 1:numfields]

    # `facedict` keeps track of the visited faces. We only need to store the first dof we
    # add to the face since currently more dofs per face isn't supported. In
    # 2D a face (i.e. a line) is uniquely determined by 2 vertices, and in 3D a face (i.e. a
    # surface) is uniquely determined by 3 vertices.
    facedicts = [Dict{NTuple{dim,Int}, Int}() for _ in 1:numfields]

    # Set initial values
    nextdof = 1  # next free dof to distribute

    @debug println("\n\nCreating dofs\n")
    for (fhi, fh) in pairs(dh.fieldhandlers)
        nextdof = _close_fieldhandler!(
            dh,
            fh,
            fhi, # TODO: Store in the FieldHandler?
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

"""
    _close_fieldhandler!(dh::DofHandler{sdim}, fh::FieldHandler, fh_index::Int, nextdof::Int, vertexdicts, edgedicts, facedicts)

Main entry point to distribute dofs for a single [`FieldHandler`](@ref) on its subdomain.
"""
function _close_fieldhandler!(dh::DofHandler{sdim}, fh::FieldHandler, fh_index::Int, nextdof::Int, vertexdicts, edgedicts, facedicts) where {sdim}
    ip_infos = InterpolationInfo[]
    for interpolation in fh.field_interpolations
        ip_info = InterpolationInfo(interpolation)
        push!(ip_infos, ip_info)
        # TODO: More than one face dof per face in 3D are not implemented yet. This requires
        #       keeping track of the relative rotation between the faces, not just the
        #       direction as for faces (i.e. edges) in 2D.
        sdim == 3 && @assert !any(x -> x > 1, ip_info.nfacedofs)
    end

    # TODO: Given the InterpolationInfo it should be possible to compute ndofs_per_cell, but
    # doesn't quite work for embedded elements right now (they don't distribute all dofs
    # "promised" by InterpolationInfo). Instead we compute it based on the number of dofs
    # added for the first cell in the set.
    first_cell = true
    ndofs_per_cell = -1

    # Mapping between the local field index and the global field index
    global_fidxs = Int[findfirst(gname -> gname === lname, dh.field_names) for lname in fh.field_names]

    # loop over all the cells, and distribute dofs for all the fields
    # TODO: Remove BitSet construction when SubDofHandler ensures sorted collections
    for ci in BitSet(fh.cellset)
        @debug println("Creating dofs for cell #$ci")

        # TODO: _check_cellset_intersections can be removed in favor of this assertion
        @assert dh.cell_to_fieldhandler[ci] == 0
        dh.cell_to_fieldhandler[ci] = fh_index

        cell = getcells(dh.grid, ci)
        len_cell_dofs_start = length(dh.cell_dofs)
        dh.cell_dofs_offset[ci] = len_cell_dofs_start + 1

        # Distribute dofs per field
        for (lidx, gidx) in pairs(global_fidxs)
            @debug println("\tfield: $(fh.field_names[lidx])")
            nextdof = _distribute_dofs_for_cell!(
                dh,
                cell,
                ip_infos[lidx],
                nextdof,
                vertexdicts[gidx],
                edgedicts[gidx],
                facedicts[gidx]
            )
        end

        if first_cell
            ndofs_per_cell = length(dh.cell_dofs) - len_cell_dofs_start
            fh.ndofs_per_cell = ndofs_per_cell
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
function _distribute_dofs_for_cell!(dh::DofHandler{sdim}, cell::AbstractCell, ip_info::InterpolationInfo, nextdof::Int, vertexdict, edgedict, facedict) where {sdim}

    # Distribute dofs for vertices
    nextdof = add_vertex_dofs(
        dh.cell_dofs, cell, vertexdict,
        ip_info.nvertexdofs, nextdof, ip_info.n_copies,
    )

    # Distribute dofs for edges (only applicable when dim is 3)
    if sdim == 3 && (ip_info.reference_dim == 3 || ip_info.reference_dim == 2)
        # Regular 3D element or 2D interpolation embedded in 3D space
        nentitydofs = ip_info.reference_dim == 3 ? ip_info.nedgedofs : ip_info.nfacedofs
        nextdof = add_edge_dofs(
            dh.cell_dofs, cell, edgedict,
            nentitydofs, nextdof,
            ip_info.adjust_during_distribution, ip_info.n_copies,
        )
    end

    # Distribute dofs for faces. Filter out 2D interpolations in 3D space, since
    # they are added above as edge dofs.
    if ip_info.reference_dim == sdim && sdim > 1
        nextdof = add_face_dofs(
            dh.cell_dofs, cell, facedict,
            ip_info.nfacedofs, nextdof,
            ip_info.adjust_during_distribution, ip_info.n_copies,
        )
    end

    # Distribute internal dofs for cells
    nextdof = add_cell_dofs(
        dh.cell_dofs, ip_info.ncelldofs, nextdof, ip_info.n_copies,
    )

    return nextdof
end

function add_vertex_dofs(cell_dofs::Vector{Int}, cell::AbstractCell, vertexdict, nvertexdofs::Vector{Int}, nextdof::Int, n_copies::Int)
    for (vi, vertex) in pairs(vertices(cell))
        nvertexdofs[vi] > 0 || continue # skip if no dof on this vertex
        @debug println("\t\tvertex #$vertex")
        first_dof = vertexdict[vertex]
        if first_dof > 0 # reuse dof
            for lvi in 1:nvertexdofs[vi], d in 1:n_copies
                # (Re)compute the next dof from first_dof by adding n_copies dofs from the
                # (lvi-1) previous vertex dofs and the (d-1) dofs already distributed for
                # the current vertex dof
                dof = first_dof + (lvi-1)*n_copies + (d-1)
                push!(cell_dofs, dof)
            end
        else # create dofs
            vertexdict[vertex] = nextdof
            for _ in 1:nvertexdofs[vi], _ in 1:n_copies
                push!(cell_dofs, nextdof)
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
@inline function get_or_create_dofs!(nextdof::Int, ndofs::Int, n_copies::Int, dict::Dict, key::Tuple)
    token = Base.ht_keyindex2!(dict, key)
    if token > 0  # vertex, face etc. visited before
        first_dof = dict.vals[token]
        dofs = first_dof : n_copies : (first_dof + n_copies * ndofs - 1)
        @debug println("\t\t\tkey: $key dofs: $(dofs)  (reused dofs)")
    else  # create new dofs
        dofs = nextdof : n_copies : (nextdof + n_copies*ndofs-1)
        @debug println("\t\t\tkey: $key dofs: $dofs")
        Base._setindex!(dict, nextdof, key, -token)
        nextdof += ndofs*n_copies
    end
    return nextdof, dofs
end

function add_face_dofs(cell_dofs::Vector{Int}, cell::AbstractCell, facedict::Dict, nfacedofs::Vector{Int}, nextdof::Int, adjust_during_distribution::Bool, n_copies::Int)
    for (fi,face) in pairs(faces(cell))
        nfacedofs[fi] > 0 || continue # skip if no dof on this vertex
        sface, orientation = sortface(face)
        @debug println("\t\tface #$sface, $orientation")
        nextdof, dofs = get_or_create_dofs!(nextdof, nfacedofs[fi], n_copies, facedict, sface)
        permute_and_push!(cell_dofs, dofs, orientation, adjust_during_distribution)
        @debug println("\t\t\tadjusted dofs: $(cell_dofs[(end - nfacedofs[fi]*n_copies + 1):end])")
    end
    return nextdof
end

function add_edge_dofs(cell_dofs::Vector{Int}, cell::AbstractCell, edgedict::Dict, nedgedofs::Vector{Int}, nextdof::Int, adjust_during_distribution::Bool, n_copies::Int)
    for (ei, edge) in pairs(edges(cell))
        if nedgedofs[ei] > 0
            sedge, orientation = sortedge(edge)
            @debug println("\t\tedge #$sedge, $orientation")
            nextdof, dofs = get_or_create_dofs!(nextdof, nedgedofs[ei], n_copies, edgedict, sedge)
            permute_and_push!(cell_dofs, dofs, orientation, adjust_during_distribution)
            @debug println("\t\t\tadjusted dofs: $(cell_dofs[(end - nedgedofs[ei]*n_copies + 1):end])")
        end
    end
    return nextdof
end

function add_cell_dofs(cell_dofs::CD, ncelldofs::Int, nextdof::Int, n_copies::Int) where {CD}
    @debug println("\t\tcelldofs #$nextdof:$(ncelldofs*n_copies-1)")
    for _ in 1:ncelldofs, _ in 1:n_copies
        push!(cell_dofs, nextdof)
        nextdof += 1
    end
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

For more details we refer to [1] as we follow the methodology described therein.

[1] Scroggs, M. W., Dokken, J. S., Richardson, C. N., & Wells, G. N. (2022).
    Construction of arbitrary order finite element degree-of-freedom maps on
    polygonal and polyhedral cell meshes. ACM Transactions on Mathematical
    Software (TOMS), 48(2), 1-23.

    !!!TODO Citation via DocumenterCitations.jl.

    !!!TODO Investigate if we can somehow pass the interpolation into this function in a typestable way.
"""
@inline function permute_and_push!(cell_dofs::Vector{Int}, dofs::StepRange{Int,Int}, orientation::PathOrientationInfo, adjust_during_distribution::Bool)
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
    return (a, b, c), SurfaceOrientationInfo() # TODO fill struct
end

function sortface(face::Tuple{Int,Int,Int,Int})
    a, b, c, d = face
    c, d = minmax(c, d)
    b, d = minmax(b, d)
    a, d = minmax(a, d)
    b, c = minmax(b, c)
    a, c = minmax(a, c)
    a, b = minmax(a, b)
    return (a, b, c), SurfaceOrientationInfo() # TODO fill struct
end

sortface(face::Tuple{Int}) = face, nothing

"""
    find_field(dh::DofHandler, field_name::Symbol)::NTuple{2,Int}

Return the index of the field with name `field_name` in a `DofHandler`. The index is a
`NTuple{2,Int}`, where the 1st entry is the index of the `FieldHandler` within which the
field was found and the 2nd entry is the index of the field within the `FieldHandler`.

!!! note
    Always finds the 1st occurence of a field within `DofHandler`.

See also: [`find_field(fh::FieldHandler, field_name::Symbol)`](@ref),
[`_find_field(fh::FieldHandler, field_name::Symbol)`](@ref).
"""
function find_field(dh::DofHandler, field_name::Symbol)
    for (fh_idx, fh) in pairs(dh.fieldhandlers)
        field_idx = _find_field(fh, field_name)
        !isnothing(field_idx) && return (fh_idx, field_idx)
    end
    error("Did not find field :$field_name in DofHandler (existing fields: $(getfieldnames(dh))).")
end

"""
    find_field(fh::FieldHandler, field_name::Symbol)::Int

Return the index of the field with name `field_name` in a `FieldHandler`. Throw an
error if the field is not found.

See also: [`find_field(dh::DofHandler, field_name::Symbol)`](@ref), [`_find_field(fh::FieldHandler, field_name::Symbol)`](@ref).
"""
function find_field(fh::FieldHandler, field_name::Symbol)
    field_idx = _find_field(fh, field_name)
    if field_idx === nothing
        error("Did not find field :$field_name in FieldHandler (existing fields: $(fh.field_names))")
    end
    return field_idx
end

# No error if field not found
"""
    _find_field(fh::FieldHandler, field_name::Symbol)::Int

Return the index of the field with name `field_name` in the `FieldHandler` `fh`. Return 
`nothing` if the field is not found.

See also: [`find_field(dh::DofHandler, field_name::Symbol)`](@ref), [`find_field(fh::FieldHandler, field_name::Symbol)`](@ref).
"""
function _find_field(fh::FieldHandler, field_name::Symbol)
    return findfirst(x -> x === field_name, fh.field_names)
end

# Calculate the offset to the first local dof of a field
function field_offset(fh::FieldHandler, field_idx::Int)
    offset = 0
    for i in 1:(field_idx-1)
        offset += getnbasefunctions(fh.field_interpolations[i])::Int
    end
    return offset
end
field_offset(fh::FieldHandler, field_name::Symbol) = field_offset(fh, find_field(fh, field_name))

field_offset(dh::DofHandler, field_name::Symbol) = field_offset(dh, find_field(dh, field_name))
function field_offset(dh::DofHandler, field_idxs::Tuple{Int, Int})
    fh_idx, field_idx = field_idxs
    field_offset(dh.fieldhandlers[fh_idx], field_idx)
end

"""
    dof_range(dh:DofHandler, field_name::Symbol)
    dof_range(fh::FieldHandler, field_name::Symbol)

Return the local dof range for a given field.

!!! note
    The `dof_range` of a field can vary between different `FieldHandler`s. Therefore, for
    problems involving multiple `FieldHandler`s, this method will throw an error when used
    on the `DofHandler` directly.

Example:
```jldoctest
julia> dh = begin
           grid = generate_grid(Triangle, (3, 3))
           dh = DofHandler(grid)
           add!(dh, :u, Lagrange{RefTriangle, 1}()^2) # vector field
           add!(dh, :p, Lagrange{RefTriangle, 1}())   # scalar field
           close!(dh)
       end

julia> dof_range(dh, :u)
1:6

julia> dof_range(dh, :p)
7:9
```
"""
function dof_range(dh::DofHandler, field_name::Symbol)
    sdh = get_only_sdh_or_error(dh, :dof_range)
    return dof_range(sdh, field_name)
end
function dof_range(fh::FieldHandler, field_name::Symbol)
    idx = find_field(fh, field_name)
    if idx === nothing
        error("field :$(field_name) not found in DofHandler/FieldHandler")
    end
    return _dof_range(fh, find_field(fh, field_name))
end
function _dof_range(fh::FieldHandler, field_idx::Int)
    offset = field_offset(fh, field_idx)
    field_interpolation = fh.field_interpolations[field_idx]
    n_field_dofs = getnbasefunctions(field_interpolation)::Int
    return (offset+1):(offset+n_field_dofs)
end

"""
    getfieldinterpolation(dh::DofHandler, field_idxs::NTuple{2,Int})
    getfieldinterpolation(dh::FieldHandler, field_idx::Int)
    getfieldinterpolation(dh::FieldHandler, field_name::Symbol)

Return the interpolation of a given field. The field can be specified by its index (see
[`find_field`](@ref) or its name.
"""
function getfieldinterpolation(dh::DofHandler, field_idxs::NTuple{2,Int})
    fh_idx, field_idx = field_idxs
    ip = dh.fieldhandlers[fh_idx].field_interpolations[field_idx]
    return ip
end
getfieldinterpolation(fh::FieldHandler, field_idx::Int) = fh.field_interpolations[field_idx]
getfieldinterpolation(fh::FieldHandler, field_name::Symbol) = getfieldinterpolation(fh, find_field(fh, field_name))

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
        data = fill(NaN * zero(T), vtk_dim, getnnodes(dh.grid))
    else
        # Just evalutation at grid nodes
        data = fill(NaN * zero(RT), getnnodes(dh.grid))
    end
    # Loop over the fieldhandlers
    for fh in dh.fieldhandlers
        # Check if this fh contains this field, otherwise continue to the next
        field_idx = _find_field(fh, fieldname)
        field_idx === nothing && continue
        # Set up CellValues with the local node coords as quadrature points
        CT = getcelltype(dh.grid, first(fh.cellset))
        ip_geo = default_interpolation(CT)
        local_node_coords = reference_coordinates(ip_geo)
        qr = QuadratureRule{getrefshape(ip)}(zeros(length(local_node_coords)), local_node_coords)
        ip = getfieldinterpolation(fh, field_idx)
        if ip isa VectorizedInterpolation
            # TODO: Remove this hack when embedding works...
            cv = CellValues(qr, ip.ip, ip_geo)
        else
            cv = CellValues(qr, ip, ip_geo)
        end
        drange = dof_range(fh, fieldname)
        # Function barrier
        _evaluate_at_grid_nodes!(data, dh, fh, u, cv, drange, RT)
    end
    return data
end

# Loop over the cells and use shape functions to compute the value
function _evaluate_at_grid_nodes!(data::Union{Vector,Matrix}, dh::DofHandler, fh::FieldHandler,
        u::Vector{T}, cv::CellValues, drange::UnitRange, ::Type{RT}) where {T, RT}
    ue = zeros(T, length(drange))
    # TODO: Remove this hack when embedding works...
    if RT <: Vec && cv isa CellValues{<:ScalarInterpolation}
        uer = reinterpret(RT, ue)
    else
        uer = ue
    end
    for cell in CellIterator(dh, fh.cellset)
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

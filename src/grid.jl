# Grid types
export Node, Cell, CellIndex, CellBoundary, CellBoundaryIndex, Grid

# Cell type alias
export Line, QuadraticLine,
       Triangle, QuadraticTriangle, Quadrilateral, QuadraticQuadrilateral,
       Tetrahedron, QuadraticTetrahedron, Hexahedron, QuadraticHexahedron

# Grid utilities
export getcells, getncells, getnodes, getnnodes, getcelltype,
       getcellset, getnodeset, getcellboundaryset, getboundaries, getcoordinates, getcoordinates!, getvertices,
       getcellsets, getnodesets, getcellboundarysets

#########################
# Main types for meshes #
#########################
"""
A `Node` is a point in space.
"""
immutable Node{dim, T}
    x::Vec{dim, T}
end
Node{dim, T}(x::NTuple{dim, T}) = Node(Vec{dim, T}(x))

"""
A `Cell` is a sub-domain defined by a collection of `Node`s as it's vertices.
"""
immutable Cell{dim, N}
    nodes::NTuple{N, Int}
end
(::Type{Cell{dim}}){dim,N}(nodes::NTuple{N}) = Cell{dim,N}(nodes)

# Typealias for commonly used cells
typealias Line Cell{1, 2}
typealias QuadraticLine Cell{1, 3}

typealias Triangle Cell{2, 3}
typealias QuadraticTriangle Cell{2, 6}
typealias Quadrilateral Cell{2, 4}
typealias QuadraticQuadrilateral Cell{2, 9}

typealias Tetrahedron Cell{3, 4}
typealias QuadraticTetrahedron Cell{3, 10} # Function interpolation for this doesn't exist in JuAFEM yet
typealias Hexahedron Cell{3, 8}
typealias QuadraticHexahedron Cell{3, 20} # Function interpolation for this doesn't exist in JuAFEM yet

"""
A `CellIndex` is returned when looping over the cells in a grid.
"""
immutable CellIndex
    idx::Int
end

"""
A `CellBoundary` is a sub-domain of the boundary defined by the cell and the side.
"""
immutable CellBoundary
    idx::Tuple{Int, Int} # cell and side
end

"""
A `CellBoundaryIndex` is returned when looping over cell boundaries of the grid.
"""
typealias CellBoundaryIndex CellBoundary

"""
A `Grid` is a collection of `Cells` and `Node`s which covers the computational domain.
"""
immutable Grid{dim, N, T <: Real}
    cells::Vector{Cell{dim, N}}
    nodes::Vector{Node{dim, T}}
    cellboundaries::Vector{CellBoundary}
    cellsets::Dict{String, Vector{Int}}
    nodesets::Dict{String, Vector{Int}}
    cellboundarysets::Dict{String, Vector{Int}}
end

function Grid{dim, N, T}(cells::Vector{Cell{dim, N}}, nodes::Vector{Node{dim, T}};
                         cellboundaries::Vector{CellBoundary} = CellBoundary[],
                         cellsets::Dict{String, Vector{Int}}=Dict{String, Vector{Int}}(),
                         nodesets::Dict{String, Vector{Int}}=Dict{String, Vector{Int}}(),
                         cellboundarysets::Dict{String, Vector{Int}}=Dict{String, Vector{Int}}())
    return Grid(cells, nodes, cellboundaries, cellsets, nodesets, cellboundarysets)
end

##########################
# Grid utility functions #
##########################
@inline getcells(grid::Grid) = grid.cells
@inline getcells(grid::Grid, v::Union{Int, Vector{Int}}) = grid.cells[v]
@inline getcells(grid::Grid, set::String) = grid.cells[grid.cellsets[set]]
@inline getncells(grid::Grid) = length(grid.cells)
@inline getcelltype(grid::Grid) = eltype(grid.cells)

@inline getnodes(grid::Grid) = grid.nodes
@inline getnodes(grid::Grid, v::Union{Int, Vector{Int}}) = grid.nodes[v]
@inline getnodes(grid::Grid, set::String) = grid.nodes[grid.nodesets[set]]
@inline getnnodes(grid::Grid) = length(grid.nodes)

@inline getboundaries(grid::Grid) = grid.cellboundaries
@inline getboundaries(grid::Grid, v::Union{Int, Vector{Int}}) = grid.cellboundaries[v]
@inline getboundaries(grid::Grid, set::String) = grid.cellboundaries[grid.cellboundarysets[set]]
@inline getnboundaries(grid::Grid) = length(grid.cellboundaries)

@inline getcellset(grid::Grid, set::String) = grid.cellsets[set]
@inline getcellsets(grid::Grid) = grid.cellsets

@inline getnodeset(grid::Grid, set::String) = grid.nodesets[set]
@inline getnodesets(grid::Grid) = grid.nodesets

@inline getcellboundaryset(grid::Grid, set::String) = grid.cellboundarysets[set]
@inline getcellboundarysets(grid::Grid) = grid.cellboundarysets


function addcellset!(grid::Grid, name::String, cellid::Vector{Int})
    haskey(grid.cellsets, name) && throw(ArgumentError("There already exists a cellset with the name: $name"))
    grid.cellsets[name] = cellid
    nothing
end
function addnodeset!(grid::Grid, name::String, nodeid::Vector{Int})
    haskey(grid.nodesets, name) && throw(ArgumentError("There already exists a nodeset with the name: $name"))
    grid.nodesets[name] = nodeid
    nothing
end

"""
Updates the coordinate vector for a cell

    getcoordinates!(x::Vector{Vec}, grid::Grid, cell::Int)
    getcoordinates!(x::Vector{Vec}, grid::Grid, cell::CellIndex)
    getcoordinates!(x::Vector{Vec}, grid::Grid, boundary::CellBoundaryIndex)

** Arguments **

* `x`: a vector of `Vec`s, one for each vertex of the cell.
* `grid`: a `Grid`
* `cell`: a `CellIndex` corresponding to a `Cell` in the grid in the grid

** Results **

* `x`: the updated vector

"""
@inline function getcoordinates!{dim, T, N}(x::Vector{Vec{dim, T}}, grid::Grid{dim, N, T}, cell::Int)
    @assert length(x) == N
    @inbounds for i in 1:N
        x[i] = grid.nodes[grid.cells[cell].nodes[i]].x
    end
    return x
end
@inline getcoordinates!{dim, T, N}(x::Vector{Vec{dim, T}}, grid::Grid{dim, N, T}, cell::CellIndex) = getcoordinates!(x, grid, cell.idx)
@inline getcoordinates!{dim, T, N}(x::Vector{Vec{dim, T}}, grid::Grid{dim, N, T}, boundary::CellBoundaryIndex) = getcoordinates!(x, grid, boundary.idx[1])

"""
Returns a vector with the coordinates of the vertices of a cell

    getcoordinates(grid::Grid, cell::Int)
    getcoordinates(grid::Grid, cell::CellIndex)
    getcoordinates(grid::Grid, boundary::CellBoundaryIndex)

** Arguments **

* `grid`: a `Grid`
* `cell`: a `CellIndex` corresponding to a `Cell` in the grid in the grid

** Results **

* `x`: A `Vector` of `Vec`s, one for each vertex of the cell.

"""
@inline function getcoordinates{dim, N, T}(grid::Grid{dim, N, T}, cell::Int)
    return [grid.nodes[i].x for i in grid.cells[cell].nodes]
end
@inline getcoordinates(grid::Grid, cell::CellIndex) = getcoordinates(grid, cell.idx)
@inline getcoordinates(grid::Grid, boundary::CellBoundaryIndex) = getcoordinates(grid, boundary.idx[1])

"""
Returns a tuple with the node numbers of the vertices of a cell

    getvertices(grid::Grid, cell::CellIndex)
    getvertices(grid::Grid, cell::BoundaryIndex)

** Arguments **

* `grid`: a `Grid`
* `cell`: a `CellIndex` corresponding to a `Cell` in the grid in the grid

** Results **

* `x`: A `Vector` of `Vec`s, one for each vertex of the cell.

"""
@inline getvertices(grid::Grid, cell::BoundaryIndex) = getcells(grid, boundary.idx[1]).nodes
@inline getvertices(grid::Grid, cell::CellIndex) = getcells(grid, cell.idx).nodes

# Iterate over cell vector
Base.start{dim, N}(c::Vector{Cell{dim, N}}) = 1
Base.next{dim, N}(c::Vector{Cell{dim, N}}, state) = (CellIndex(state), state + 1)
Base.done{dim, N}(c::Vector{Cell{dim, N}}, state) = state > length(c)

module JuAFEM
using Reexport
@reexport using Tensors
@reexport using WriteVTK

using LinearAlgebra
using SparseArrays

using Base: @propagate_inbounds

include("exports.jl")

"""
Represents a reference shape which quadrature rules and interpolations are defined on.
Currently, the only concrete types that subtype this type are `RefCube` in 1, 2 and 3 dimensions,
and `RefTetrahedron` in 2 and 3 dimensions.
"""
abstract type AbstractRefShape end

struct RefTetrahedron <: AbstractRefShape end
struct RefCube <: AbstractRefShape end

"""
Abstract type which has `CellValues` and `FaceValues` as subtypes
"""
abstract type Values{dim,T,refshape} end
abstract type CellValues{dim,T,refshape} <: Values{dim,T,refshape} end
abstract type FaceValues{dim,T,refshape} <: Values{dim,T,refshape} end

include("utils.jl")

# Interpolations
include("interpolations.jl")

# Quadrature
include(joinpath("Quadrature", "quadrature.jl"))

# FEValues
include(joinpath("FEValues","cell_values.jl"))
include(joinpath("FEValues","face_values.jl"))
include(joinpath("FEValues","common_values.jl"))
include(joinpath("FEValues","face_integrals.jl"))

# Grid
include(joinpath("Grid", "grid.jl"))
include(joinpath("Grid", "MixedGrid.jl"))
include(joinpath("Grid", "grid_generators.jl"))
include(joinpath("Grid", "coloring.jl"))

# Dofs
include(joinpath("Dofs", "DofHandler.jl"))
include(joinpath("Dofs", "MixedDofHandler.jl"))
include(joinpath("Dofs", "ConstraintHandler.jl"))

include("iterators.jl")

# Assembly
include("assembler.jl")

# Export
include(joinpath("Export", "VTK.jl"))

# Other
include("deprecations.jl")

end # module

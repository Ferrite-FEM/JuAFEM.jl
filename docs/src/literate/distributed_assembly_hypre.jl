# # Distributed Assembly of Heat Equation
#
# ## Introduction
#
# Now we want to solve the heat problem in parallel. To be specific, this example shows
# how to utilize process parallelism to assemble finite element matrices in parallel.
# This example presumes that the reader is familiar with solving the heat problem in
# serial with Ferrite.jl, as presented in [the first example](@ref heat_example).
#
#-
# ## Commented Program
#
# Now we solve the problem in Ferrite. What follows is a program spliced with comments.
#md # The full program, without comments, can be found in the next [section](@ref heat_equation-plain-program).
#
# First we load Ferrite, and some other packages we need
using Ferrite, MPI
using HYPRE
using PartitionedArrays, Metis

# Launch MPI
MPI.Init()
HYPRE.Init()

function Ferrite.create_sparsity_pattern(::Type{<:HYPREMatrix}, dh::DofHandler, ch::Union{ConstraintHandler,Nothing}=nothing; kwargs...)
    println("Ferrite.create_sparsity_pattern")
    K = create_sparsity_pattern(dh, ch; kwargs...)
    fill!(K.nzval, 1)
    return HYPREMatrix(K)
end

###########################################
## HYPREAssembler and associated methods ##
###########################################

struct HYPREAssembler <: Ferrite.AbstractSparseAssembler
    A::HYPRE.HYPREAssembler
end

Ferrite.matrix_handle(a::HYPREAssembler) = a.A.A.A # :)
Ferrite.vector_handle(a::HYPREAssembler) = a.A.b.b # :)

function Ferrite.start_assemble(K::HYPREMatrix, f::HYPREVector)
    println("Ferrite.start_assemble")
    return HYPREAssembler(HYPRE.start_assemble!(K, f))
end

function Ferrite.assemble!(a::HYPREAssembler, dofs::AbstractVector{<:Integer}, ke::AbstractMatrix, fe::AbstractVector)
    println("Ferrite.assemble!")
    HYPRE.assemble!(a.A, dofs, ke, fe)
end


## Methods for arrayutils.jl ##

function Ferrite.addindex!(A::HYPREMatrix, v, i::Int, j::Int)
    println("Ferrite.addindex!")
    nrows = HYPRE_Int(1)
    ncols = Ref{HYPRE_Int}(1)
    rows = Ref{HYPRE_BigInt}(i)
    cols = Ref{HYPRE_BigInt}(j)
    values = Ref{HYPRE_Complex}(v)
    HYPRE.@check HYPRE_IJMatrixAddToValues(A.ijmatrix, nrows, ncols, rows, cols, values)
    return A
end

function Ferrite.addindex!(b::HYPREVector, v, i::Int)
    println("Ferrite.addindex!")
    nvalues = HYPRE_Int(1)
    indices = Ref{HYPRE_BigInt}(i)
    values = Ref{HYPRE_Complex}(v)
    HYPRE.@check HYPRE_IJVectorAddToValues(b.ijvector, nvalues, indices, values)
    return b
end

FerritePartitionedArrays = Base.get_extension(Ferrite, :FerritePartitionedArrays)

# We start generating a simple grid with 20x20 quadrilateral elements
# and distribute it across our processors using `generate_distributed_grid`. 
# dgrid = FerritePartitionedArrays.generate_distributed_grid(QuadraticQuadrilateral, (3, 1));
# dgrid = FerritePartitionedArrays.generate_distributed_grid(Tetrahedron, (2, 2, 2));
dgrid = FerritePartitionedArrays.generate_distributed_grid(Hexahedron, (2, 2, 2)); #src
# dgrid = FerritePartitionedArrays.generate_distributed_grid(Tetrahedron, (3, 3, 3)); #src

# ### Trial and test functions
# Nothing changes here.
dim = 2
dim = 3 #src
ref = RefCube
# ref = RefTetrahedron #src
ip = Lagrange{dim, ref, 1}()
ip = Lagrange{dim, ref, 2}() #src
ip_geo = Lagrange{dim, ref, 1}()
qr = QuadratureRule{dim, ref}(2)
qr = QuadratureRule{dim, ref}(4) #src
cellvalues = CellScalarValues(qr, ip, ip_geo);

# ### Degrees of freedom
# To handle the dofs correctly we now utilize the `DistributedDofHandle` 
# instead of the `DofHandler`. For the user the interface is the same.
dh = FerritePartitionedArrays.DistributedDofHandler(dgrid)
push!(dh, :u, 1, ip)
close!(dh);
# Hypre needs locally continuous indices.
FerritePartitionedArrays.hypre_reorder!(dh);

# ### Boundary conditions
# Nothing has to be changed here either.
ch = ConstraintHandler(dh);
∂Ω = union(getfaceset.((dgrid, ), ["left", "right", "top", "bottom"])...);
∂Ω = union(getfaceset.((dgrid, ), ["left", "right", "top", "bottom", "front", "back"])...); #src
dbc = Dirichlet(:u, ∂Ω, (x, t) -> 0)
dbc_val = 0 #src
dbc = Dirichlet(:u, ∂Ω, (x, t) -> dbc_val) #src
add!(ch, dbc);
close!(ch)
# update!(ch, 0.0);

my_rank = MPI.Comm_rank(MPI.COMM_WORLD)
# println("R$my_rank: prescribing $(ch.prescribed_dofs) on $∂Ω")

# ### Assembling the linear system
# Assembling the system works also mostly analogue.
function doassemble(cellvalues::CellScalarValues{dim}, dh::FerritePartitionedArrays.DistributedDofHandler, ch::ConstraintHandler) where {dim}
    n_basefuncs = getnbasefunctions(cellvalues)
    Ke = zeros(n_basefuncs, n_basefuncs)
    fe = zeros(n_basefuncs)

    # comm = global_comm(getglobalgrid(dh))
    comm = MPI.COMM_WORLD
    ilower = dh.ldof_to_gdof[1]
    iupper = dh.ldof_to_gdof[1]+FerritePartitionedArrays.num_local_true_dofs(dh)-1
    @show ilower, iupper
    K = HYPREMatrix(comm, ilower, iupper)
    f = HYPREVector(comm, ilower, iupper)

    # --------------------- Distributed assembly --------------------
    # The synchronization with the global sparse matrix is handled by 
    # an assembler again. You can choose from different backends, which
    # are described in the docs and will be expaned over time. This call
    # may trigger a large amount of communication.
    # NOTE: At the time of writing the only backend available is a COO 
    #       assembly via PartitionedArrays.jl .
    assembler = start_assemble(K, f)

    # For the local assembly nothing changes
    for cell in CellIterator(dh)
        fill!(Ke, 0)
        fill!(fe, 0)

        reinit!(cellvalues, cell)
        coords = getcoordinates(cell)
                
        for q_point in 1:getnquadpoints(cellvalues)
            dΩ = getdetJdV(cellvalues, q_point)
            
            for i in 1:n_basefuncs
                v  = shape_value(cellvalues, q_point, i)
                ∇v = shape_gradient(cellvalues, q_point, i)
                # Manufactured solution of Π cos(xᵢπ)
                x = spatial_coordinate(cellvalues, q_point, coords)
                fe[i] += (π/2)^2 * dim * prod(cos, x*π/2) * v * dΩ

                for j in 1:n_basefuncs
                    ∇u = shape_gradient(cellvalues, q_point, j)
                    Ke[i, j] += (∇v ⋅ ∇u) * dΩ
                end
            end
        end

        apply_local!(Ke, fe, celldofs(cell), ch)
        Ferrite.assemble!(assembler, dh.ldof_to_gdof[celldofs(cell)], fe, Ke)
    end

    # Finally, for the `PartitionedArraysCOOAssembler` we have to call
    # `end_assemble` to construct the global sparse matrix and the global
    # right hand side vector.
    HYPRE.finish_assemble!(assembler.A)
    return K, f
end
#md nothing # hide

# ### Solution of the system
# Again, we assemble our problem and apply the constraints as needed.
K, f = doassemble(cellvalues, dh, ch);

precond = HYPRE.BoomerAMG()
solver = HYPRE.PCG(; Precond = precond)
xh = HYPRE.solve(solver, K, f)

# Copy solution from HYPRE to Julia
x = Vector{Float64}(undef, FerritePartitionedArrays.num_local_true_dofs(dh))
copy!(x, xh)

# Collect to root rank
# if my_rank == 1
#     X = Vector{Float64}(undef, 45)
#     counts = [27+9,27-9]
#     MPI.Gatherv!(x, VBuffer(X, [counts]), MPI.COMM_WORLD)
#     @show norm(X)
# else
#     MPI.Gatherv!(x, nothing, MPI.COMM_WORLD)
# end
@show x

# # ### Exporting via PVTK
# # To visualize the result we export the grid and our field `u`
# # to a VTK-file, which can be viewed in e.g. [ParaView](https://www.paraview.org/).
# vtk_grid("heat_equation_distributed", dh) do vtk
#     vtk_point_data(vtk, dh, u)
#     # For debugging purposes it can be helpful to enrich 
#     # the visualization with some meta  information about 
#     # the grid and its partitioning
#     FerritePartitionedArrays.vtk_shared_vertices(vtk, dgrid)
#     FerritePartitionedArrays.vtk_shared_faces(vtk, dgrid)
#     FerritePartitionedArrays.vtk_shared_edges(vtk, dgrid) #src
#     FerritePartitionedArrays.vtk_partitioning(vtk, dgrid)
# end

# ## Test the result against the manufactured solution                    #src
# using Test                                                              #src
# for cell in CellIterator(dh)                                            #src
#     reinit!(cellvalues, cell)                                           #src
#     n_basefuncs = getnbasefunctions(cellvalues)                         #src
#     coords = getcoordinates(cell)                                       #src
#     map_parts(local_view(u, u.rows)) do u_local                         #src
#         uₑ = u_local[celldofs(cell)]                                    #src
#         for q_point in 1:getnquadpoints(cellvalues)                     #src
#             x = spatial_coordinate(cellvalues, q_point, coords)         #src
#             for i in 1:n_basefuncs                                      #src
#                 uₐₙₐ    = prod(cos, x*π/2)+dbc_val                      #src
#                 uₐₚₚᵣₒₓ = function_value(cellvalues, q_point, uₑ)       #src
#                 @test isapprox(uₐₙₐ, uₐₚₚᵣₒₓ; atol=1e-1)                #src
#             end                                                         #src
#         end                                                             #src
#     end                                                                 #src
# end                                                                     #src

# Finally, we gracefully shutdown MPI
# MPI.Finalize()

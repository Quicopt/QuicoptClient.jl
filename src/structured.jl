# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# ── structured decision variables: permutations, partitions, lookup tables ───
#
# A permutation, a partition and a lookup table are declared on a JuMP model and
# stand in its expressions through a *handle*: an ordinary JuMP variable named
# after the declaration, which the importer never emits as a decision variable —
# the same device as a random variable's (see `set_distribution`). JuMP builds a
# nonlinear node only around at least one JuMP scalar, and the handle is that
# scalar: `item_at(k, tour)` is the node `item_at(k, <handle>)`, and the importer
# finds the declaration by the handle's index. The heads `:item_at`, `:slot_of`,
# `:part_of` and `:size_of` are catalog operators; `:lookup` is this package's
# own and becomes a `TableRef`. Like the stochastic heads they are data: no
# local evaluator sees them. A block needs no handle: it lists the model's own
# variables, and `active(x)` is the catalog's `indicator` of one of them.

"""
    _PermutationDecl

One declared permutation: its `name`, its number of items `n_items`, the
`start` slot of each item (empty for the default) and its `(before, after)`
precedences in the order given.
"""
struct _PermutationDecl
    name::Symbol
    n_items::Int
    start::Vector{Int}
    precede::Vector{Tuple{Int,Int}}
end

"""
    _PartitionDecl

One declared partition: its `name`, its number of items `n_items`, its number
of parts `n_parts` and the `start` part of each item (empty for the default).
"""
struct _PartitionDecl
    name::Symbol
    n_items::Int
    n_parts::Int
    start::Vector{Int}
end

"""
    _Structured

A model's structured declarations: its permutations, partitions and lookup
tables (name and entries), keyed by the index of each handle variable, and its
blocks, by name, each the list of its member variables in the order given. Held
in `model.ext[:quicopt_structured]` and read by `import_model`.
"""
struct _Structured
    permutations::Dict{MOI.VariableIndex,_PermutationDecl}
    partitions::Dict{MOI.VariableIndex,_PartitionDecl}
    tables::Dict{MOI.VariableIndex,Pair{Symbol,Array{Float64}}}
    blocks::Dict{Symbol,Vector{MOI.VariableIndex}}
end

_structured!(m::JuMP.Model) =
    get!(() -> _Structured(Dict{MOI.VariableIndex,_PermutationDecl}(),
                           Dict{MOI.VariableIndex,_PartitionDecl}(),
                           Dict{MOI.VariableIndex,Pair{Symbol,Array{Float64}}}(),
                           Dict{Symbol,Vector{MOI.VariableIndex}}()),
         m.ext, :quicopt_structured)::_Structured
_structured(m::JuMP.Model) = get(m.ext, :quicopt_structured, nothing)

"""
    _declare_handle!(m, name) -> (record, handle)

Check that `name` is free among the model's permutations, partitions and lookup
tables, and create the handle variable that will stand for the new declaration.
"""
function _declare_handle!(m::JuMP.Model, name::Symbol)
    st = _structured!(m)
    taken = Set{Symbol}(d.name for d in values(st.permutations)) ∪
            Set{Symbol}(d.name for d in values(st.partitions)) ∪
            Set{Symbol}(t.first for t in values(st.tables))
    name in taken && error("the name :$name is already declared on this model")
    return st, JuMP.@variable(m, base_name = String(name))
end

# ── permutations ─────────────────────────────────────────────────────────────

"""
    Permutation

A permutation declared by [`permutation`](@ref): items placed in as many slots,
one item per slot, both numbered from 1. `P.n_items` is the number of items.
Read it with [`item_at`](@ref) and [`slot_of`](@ref); constrain it with
[`precede!`](@ref).
"""
struct Permutation
    handle::JuMP.VariableRef
    name::Symbol
    n_items::Int
end

Base.broadcastable(P::Permutation) = Ref(P)
Base.show(io::IO, P::Permutation) =
    print(io, "permutation :", P.name, " (", P.n_items, " items in ", P.n_items, " slots)")

"""
    permutation(model, name, n_items; start = nothing) -> Permutation

Declare an ordering as a decision: `n_items` items placed in as many slots, one
item per slot. For a route the items are the stops and the slots are the visits,
so slot 1 holds the first stop visited; for a machine the items are the jobs and
the slots the positions in its queue.

`name` identifies the permutation in the result, as
`result.structures[name]`. `n_items` is at least 2. `start` is the arrangement
the service's search starts from: `start[i]` is the slot of item `i`, so it
holds each of `1:n_items` once. Left out, item `i` starts in slot `i`.

A model with a permutation is solved by a search, so its result has the status
`"heuristic"`.

# Example
Five stops along a road; find the shortest route through all of them that
visits stop 4 before stop 1:

```julia
using QuicoptClient, JuMP

position = [0, 3, 1, 4, 2]                        # km along the road, stops 1 to 5
m = Model()
dist  = lookup_table(m, :dist, [abs(a - b) for a in position, b in position])
route = permutation(m, :route, 5)
precede!(route, 4, 1)                             # stop 4 is visited before stop 1
@objective(m, Min, sum(dist[item_at(k, route), item_at(k + 1, route)] for k in 1:4))

result = solve(m)
result.objective                                  # 4.0
result.structures.route.item_at                   # [4, 2, 5, 3, 1]: the stops in the order visited
```
"""
function permutation(m::JuMP.Model, name::Union{Symbol,AbstractString}, n_items::Integer;
                     start = nothing)
    n_items ≥ 2 || error("a permutation has at least 2 items, got $n_items")
    nm = Symbol(name)
    s = start === nothing ? Int[] : collect(start)
    isempty(s) || (all(x -> x isa Integer, s) && sort(s) == 1:n_items) ||
        error("permutation :$nm: start must hold each of 1 to $n_items once " *
              "(start[i] is the slot item i starts in)")
    st, handle = _declare_handle!(m, nm)
    st.permutations[JuMP.index(handle)] = _PermutationDecl(nm, Int(n_items), Int.(s), Tuple{Int,Int}[])
    return Permutation(handle, nm, Int(n_items))
end

"""
    _position(k, P, what, caller) -> Int

Check that `k`, a slot or an item of `P`, is a whole number in `1:P.n_items`.
"""
function _position(k, P::Permutation, what, caller)
    k isa Integer || error("$caller: a $what is a whole number, got $(repr(k))")
    1 ≤ k ≤ P.n_items ||
        error("$caller: permutation :$(P.name) has $(what)s 1 to $(P.n_items), got $k")
    return Int(k)
end

"""
    item_at(slot, P::Permutation) -> NonlinearExpr

The item in slot `slot` of the permutation `P`, an expression whose value the
service chooses. For a route whose items are stops, `item_at(1, route)` is the
first stop visited. Index a [`lookup_table`](@ref) with it to read data about
that item. `slot` is a whole number from 1 to the size of `P`; broadcast for
several, as in `item_at.(1:4, route)`.
"""
item_at(slot, P::Permutation) = JuMP.NonlinearExpr(:item_at, _position(slot, P, "slot", "item_at"), P.handle)

"""
    slot_of(item, P::Permutation) -> NonlinearExpr

The slot that item `item` is placed in, an expression whose value the service
chooses. For a route whose items are stops, `slot_of(3, route)` is when stop 3
is visited. `item` is a whole number from 1 to the size of `P`.
"""
slot_of(item, P::Permutation) = JuMP.NonlinearExpr(:slot_of, _position(item, P, "item", "slot_of"), P.handle)

"""
    precede!(P::Permutation, before, after) -> Permutation

Require item `before` to be in an earlier slot of `P` than item `after`: a
pickup before its delivery, or a job before the job that needs its output. The
service only considers arrangements that meet every such requirement, so every
solution meets it. Requirements that contradict each other, such as 1 before 2
and 2 before 1, are an error.
"""
function precede!(P::Permutation, before, after)
    a = _position(before, P, "item", "precede!")
    b = _position(after, P, "item", "precede!")
    a == b && error("an item cannot precede itself")
    decl = _structured(JuMP.owner_model(P.handle)).permutations[JuMP.index(P.handle)]
    _has_cycle(vcat(decl.precede, [(a, b)]), P.n_items) &&
        error("requiring $a before $b contradicts the requirements already given for :$(P.name)")
    push!(decl.precede, (a, b))
    return P
end

"""
    _has_cycle(edges, n_items) -> Bool

Whether the `(before, after)` requirements over items `1:n_items` contradict
each other: Kahn's algorithm leaves an item unplaced exactly when they contain a
cycle.
"""
function _has_cycle(edges, n_items::Int)
    indegree = zeros(Int, n_items)
    for (_, b) in edges
        indegree[b] += 1
    end
    ready = findall(iszero, indegree)
    placed = 0
    while !isempty(ready)
        x = pop!(ready)
        placed += 1
        for (a, b) in edges
            a == x || continue
            indegree[b] -= 1
            indegree[b] == 0 && push!(ready, b)
        end
    end
    return placed < n_items
end

# ── partitions ───────────────────────────────────────────────────────────────

"""
    Partition

A partition declared by [`partition`](@ref): items placed in parts, both
numbered from 1. `P.n_items` is the number of items and `P.n_parts` the number
of parts. Read it with [`part_of`](@ref) and [`size_of`](@ref).
"""
struct Partition
    handle::JuMP.VariableRef
    name::Symbol
    n_items::Int
    n_parts::Int
end

Base.broadcastable(P::Partition) = Ref(P)
Base.show(io::IO, P::Partition) =
    print(io, "partition :", P.name, " (", P.n_items, " items in ", P.n_parts, " parts)")

"""
    partition(model, name, n_items, n_parts; start = nothing) -> Partition

Declare a split into groups as a decision: each of `n_items` items goes into one
of `n_parts` parts. The items might be people and the parts teams, or jobs and
the machines that run them. A part may stay empty.

`name` identifies the partition in the result, as `result.structures[name]`.
`n_items` is at least 1 and `n_parts` at least 2. `start` is the assignment the
service's search starts from: `start[i]` is the part of item `i`, each in
`1:n_parts`. Left out, item `i` starts in part `1 + (i - 1) % n_parts`.

A model with a partition is solved by a search, so its result has the status
`"heuristic"`.

# Example
Six players of strengths 7, 5, 4, 3, 2 and 1 form a team of four and a team of
two, as evenly matched as possible:

```julia
using QuicoptClient, JuMP

strength = [7, 5, 4, 3, 2, 1]                     # of players 1 to 6
m = Model()
teams = partition(m, :teams, 6, 2)                # 6 players into teams 1 and 2
@expression(m, total[t = 1:2], sum(ifelse(part_of(p, teams) == t, strength[p], 0) for p in 1:6))
@constraint(m, size_of(1, teams) == 4)            # team 1 has four players
@objective(m, Min, max(total[1], total[2]))

result = solve(m)
result.objective                                  # 11.0
result.structures.teams.part_of                   # [2, 1, 2, 1, 1, 1]: each player's team
result.structures.teams.size_of                   # [4, 2]: how many players in each team
```

Players 1 and 3 (7 + 4) make up the team of two, and the other four also add up
to 11.
"""
function partition(m::JuMP.Model, name::Union{Symbol,AbstractString}, n_items::Integer,
                   n_parts::Integer; start = nothing)
    nm = Symbol(name)
    n_items ≥ 1 || error("partition :$nm needs at least 1 item, got $n_items")
    n_parts ≥ 2 || error("partition :$nm needs at least 2 parts, got $n_parts")
    s = start === nothing ? Int[] : collect(start)
    isempty(s) || (length(s) == n_items && all(b -> b isa Integer && 1 ≤ b ≤ n_parts, s)) ||
        error("partition :$nm: start must give each of the $n_items items a part in 1:$n_parts " *
              "(start[i] is the part item i starts in)")
    st, handle = _declare_handle!(m, nm)
    st.partitions[JuMP.index(handle)] = _PartitionDecl(nm, Int(n_items), Int(n_parts), Int.(s))
    return Partition(handle, nm, Int(n_items), Int(n_parts))
end

"""
    part_of(item, P::Partition) -> NonlinearExpr

The part that item `item` is in, an expression whose value the service chooses:
a whole number from 1 to the number of parts of `P`. Index a
[`lookup_table`](@ref) with it to read data about that part. `item` is a whole
number from 1 to the number of items of `P`; broadcast for several, as in
`part_of.(1:5, teams)`.
"""
function part_of(item, P::Partition)
    item isa Integer || error("part_of: an item is a whole number, got $(repr(item))")
    1 ≤ item ≤ P.n_items ||
        error("part_of: partition :$(P.name) has items 1 to $(P.n_items), got $item")
    return JuMP.NonlinearExpr(:part_of, Int(item), P.handle)
end

"""
    size_of(part, P::Partition) -> NonlinearExpr

How many items part `part` of `P` holds, an expression whose value the service
chooses: a whole number from 0 to the number of items. `part` is a whole number
from 1 to the number of parts of `P`.
"""
function size_of(part, P::Partition)
    part isa Integer || error("size_of: a part is a whole number, got $(repr(part))")
    1 ≤ part ≤ P.n_parts ||
        error("size_of: partition :$(P.name) has parts 1 to $(P.n_parts), got $part")
    return JuMP.NonlinearExpr(:size_of, Int(part), P.handle)
end

# ── variables that may be 0: in use, and grouped into blocks ─────────────────

"""
    active(x) -> NonlinearExpr

Whether the variable `x` is in use: an expression that is 1 when `x` is not 0
and 0 when it is. It is meant for a variable declared with JuMP's
`Semicontinuous` or `Semiinteger` set, which is 0 or within the set's range,
such as a delivery of either nothing or 10 to 25 units. A fee per delivery is
then `fee * active(x)`, and a model that is otherwise linear stays one the
service solves exactly.

```julia
@variable(m, ship in Semiinteger(10, 25))         # none, or 10 to 25 units
@objective(m, Min, 2ship + 30active(ship))        # a price per unit and a fee per delivery
```
"""
active(x::JuMP.VariableRef) = JuMP.NonlinearExpr(:indicator, x)

"""
    block(model, name, vars)

Declare the variables `vars` as one block: the variables of one subproblem of
the model, such as one customer's deliveries or one project's staffing. Every
solution the service returns satisfies the constraints that involve only one
block's variables, such as that customer's demand. A block changes nothing else
about the model. Each variable is in at most one block and needs finite bounds;
`name` identifies the block and must not be used twice.

# Example
Three warehouses supply three customers. Each delivery is none or 10 to 25
units and costs 5 plus a price per unit; a warehouse that delivers anything
pays its opening fee:

```julia
using QuicoptClient, JuMP

demand = [40, 30, 20]                             # units, customers 1 to 3
price = [1 3 4; 3 1 3; 4 2 1]                     # per unit, price[warehouse, customer]
opening = [60, 50, 40]                            # fee of warehouses 1 to 3
m = Model()
@variable(m, ship[1:3, 1:3] in Semiinteger(10, 25))   # every delivery: none, or 10 to 25 units
for c in 1:3
    block(m, "customer_\$c", ship[:, c])
    @constraint(m, sum(ship[:, c]) >= demand[c])
end
@objective(m, Min, sum(price .* ship) + sum(5active(ship[w, c]) for w in 1:3, c in 1:3) +
                   sum(ifelse(sum(ship[w, :]) >= 1, opening[w], 0) for w in 1:3))

result = solve(m)
result.objective                                  # 300.0
[result.solution[Symbol("x", index(ship[w, c]).value)] for w in 1:3, c in 1:3]
# 3×3 Matrix{Float64}:
#  25.0  10.0   0.0
#   0.0   0.0   0.0
#  15.0  20.0  20.0
```

Warehouse 2 stays closed. Warehouse 1 sends its full 25 units to customer 1 and
the minimum of 10 to customer 2; warehouse 3 covers the rest. Without the
minimum load, the cheapest plan would cost 295 and send customer 2 a delivery of
only 5 units from warehouse 1.

The opening fee is JuMP's `ifelse` over a comparison, written inside a JuMP
macro (`@objective`, `@expression`, `@constraint`), where a comparison of
variables is an expression; any of `>=`, `<=`, `>`, `<` and `==` works.
"""
function block(m::JuMP.Model, name::Union{Symbol,AbstractString}, vars)
    nm = Symbol(name)
    st = _structured!(m)
    haskey(st.blocks, nm) && error("the block :$nm is already declared on this model")
    members = MOI.VariableIndex[]
    for v in vars
        v isa JuMP.VariableRef || error("block :$nm: a member is a variable, got $(repr(v))")
        JuMP.owner_model(v) === m || error("block :$nm: variable $v belongs to another model")
        push!(members, JuMP.index(v))
    end
    isempty(members) && error("block :$nm has no variables")
    for (other, ms) in st.blocks, vi in members
        vi in ms && error("variable $(JuMP.VariableRef(m, vi)) is already in the block :$other")
    end
    allunique(members) || error("block :$nm lists a variable twice")
    st.blocks[nm] = members
    return nothing
end

# ── lookup tables ────────────────────────────────────────────────────────────

"""
    LookupTable

A table of data declared by [`lookup_table`](@ref), to be indexed with
expressions: `table[i]` for a vector, `table[i, j]` for a matrix.
"""
struct LookupTable{N}
    handle::JuMP.VariableRef
    name::Symbol
    values::Array{Float64,N}
end

Base.broadcastable(t::LookupTable) = Ref(t)
Base.show(io::IO, t::LookupTable) = print(io, "lookup table :", t.name, " (", join(size(t.values), " × "), ")")

"""
    lookup_table(model, name, values) -> LookupTable

Declare a table of data that can be indexed by decisions. A model sometimes
needs a number from a table at a position that is not known yet: the distance
between the first and the second stop of a route whose ordering the service
is still choosing, or the price of an option an integer variable picks. A
Julia array cannot be indexed this way; the table returned here can.

`values` is a vector (indexed `table[i]`) or a matrix (`table[i, j]`) of numbers,
none of them `NaN`. Indexing with whole numbers only gives the entry itself;
indexing with an expression, such as [`item_at`](@ref) or an integer variable,
gives an expression whose value is the entry at the positions the service
chooses. An index value that is not a whole number is rounded, and one outside
the table is moved to its nearest end.

The whole table is sent with the model, so a very large table makes the request
large.
"""
function lookup_table(m::JuMP.Model, name::Union{Symbol,AbstractString},
                      values::Union{AbstractVector{<:Real},AbstractMatrix{<:Real}})
    nm = Symbol(name)
    isempty(values) && error("lookup table :$nm has no entries")
    any(isnan, values) && error("lookup table :$nm holds NaN")
    data = Array{Float64}(values)
    st, handle = _declare_handle!(m, nm)
    st.tables[JuMP.index(handle)] = nm => data
    return LookupTable(handle, nm, data)
end

Base.getindex(t::LookupTable{1}, i) = _lookup(t, i)
Base.getindex(t::LookupTable{2}, i, j) = _lookup(t, i, j)

"""
    _lookup(t, idx...) -> Float64 or NonlinearExpr

The entry of `t` at `idx`: the number itself when every index is a whole number,
else a `:lookup` node over the table's handle and the indices.
"""
function _lookup(t::LookupTable, idx...)
    for (k, extent) in zip(idx, size(t.values))
        if k isa Integer
            1 ≤ k ≤ extent || error("lookup table :$(t.name): a whole-number index runs from 1 to $extent, got $k")
        elseif k isa Real
            error("lookup table :$(t.name): an index is a whole number or an expression, got $k")
        end
    end
    all(k -> k isa Integer, idx) && return t.values[idx...]
    return JuMP.NonlinearExpr(:lookup, t.handle, idx...)
end

# ── import: declarations → Program fields ────────────────────────────────────

"""
    _structure_kinds(st) -> Dict{MOI.VariableIndex,Pair{Symbol,Symbol}}

Each structure handle's declaration name and kind (`:permutation`,
`:partition`), as the importer reads them.
"""
_structure_kinds(st::_Structured) =
    merge(Dict(vi => (d.name => :permutation) for (vi, d) in st.permutations),
          Dict(vi => (d.name => :partition) for (vi, d) in st.partitions))

"""
    _structure_decls(st) -> Vector{StructureDecl}

The model's permutations and partitions as wire declarations, in canonical
(name-sorted) order. A start that places an item after one it must follow is
refused here, where both are known; the service would refuse it too.
"""
function _structure_decls(st::_Structured)
    decls = vcat(_permutation_decls(st), _partition_decls(st))
    return sort!(decls; by = d -> d.name)
end

"""
    _partition_decls(st) -> Vector{StructureDecl}

The model's partitions as wire declarations: kind `"partition"`, the items as
`size`, the parts as `parts`, the start one part per item.
"""
_partition_decls(st::_Structured) =
    _pb.StructureDecl[_pb.StructureDecl(name = String(d.name), kind = "partition",
                                        size = UInt64(d.n_items),
                                        start = Int64.(d.start), fixed = false,
                                        precede = _pb.Precedence[], parts = UInt64(d.n_parts))
                      for d in values(st.partitions)]

"""
    _block_decls(st, srcs, handles, lo, hi) -> Vector{BlockDecl}

The model's blocks as wire declarations, in canonical (name-sorted) order, each
member a reference to its decision variable. A member that is a random variable
(`srcs`) or a structure handle (`handles`), or that has an infinite bound (`lo`,
`hi`), is refused.
"""
function _block_decls(st::_Structured, srcs, handles, lo, hi)
    decls = _pb.BlockDecl[]
    for nm in sort(collect(keys(st.blocks)); by = String)
        refs = _pb.VarRef[]
        for vi in st.blocks[nm]
            (haskey(srcs, vi) || haskey(handles, vi)) &&
                error("block :$nm lists a random variable or a structure, not a decision variable")
            (isfinite(lo[vi]) && isfinite(hi[vi])) ||
                error("block :$nm: variable x$(vi.value) has bounds [$(lo[vi]), $(hi[vi])]; " *
                      "a block's variables need finite bounds")
            push!(refs, _pb.VarRef(name = "x$(vi.value)", index = _index(())))
        end
        push!(decls, _pb.BlockDecl(name = String(nm), members = refs))
    end
    return decls
end

"""
    _permutation_decls(st) -> Vector{StructureDecl}

The model's permutations as wire declarations.
"""
function _permutation_decls(st::_Structured)
    decls = _pb.StructureDecl[]
    for d in values(st.permutations)
        for (a, b) in d.precede
            isempty(d.start) || d.start[a] < d.start[b] ||
                error("permutation :$(d.name): the start places item $a after item $b, which it must precede")
        end
        push!(decls, _pb.StructureDecl(name = String(d.name), kind = "permutation",
                                       size = UInt64(d.n_items),
                                       start = Int64.(d.start), fixed = false,
                                       precede = _pb.Precedence[_pb.Precedence(before = UInt64(a), after = UInt64(b))
                                                                for (a, b) in d.precede]))
    end
    return decls
end

"""
    _table_params(st) -> Vector{ParamTable}

The model's lookup tables as parameter tables, in canonical (name-sorted) order,
one entry per cell keyed by its position.
"""
function _table_params(st::_Structured)
    tables = sort(collect(values(st.tables)); by = t -> String(t.first))
    return _pb.ParamTable[_pb.ParamTable(name = String(nm),
                                         entries = _pb.ParamEntry[_pb.ParamEntry(key = _index(Tuple(c)), value = A[c])
                                                                  for c in vec(CartesianIndices(A))])
                          for (nm, A) in tables]
end

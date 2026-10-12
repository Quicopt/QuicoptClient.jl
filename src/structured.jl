# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# ── structured decision variables: permutations and lookup tables ────────────
#
# A permutation and a lookup table are declared on a JuMP model and stand in its
# expressions through a *handle*: an ordinary JuMP variable named after the
# declaration, which the importer never emits as a decision variable — the same
# device as a random variable's (see `set_distribution`). JuMP builds a
# nonlinear node only around at least one JuMP scalar, and the handle is that
# scalar: `item_at(k, tour)` is the node `item_at(k, <handle>)`, and the importer
# finds the declaration by the handle's index. The heads `:item_at` and
# `:slot_of` are catalog operators; `:lookup` is this package's own and becomes
# a `TableRef`. Like the stochastic heads they are data: no local evaluator sees
# them.

"""
    _PermutationDecl

One declared permutation: its `name`, its size `n`, the `start` slot of each
item (empty for the default) and its `(before, after)` precedences in the order
given.
"""
struct _PermutationDecl
    name::Symbol
    n::Int
    start::Vector{Int}
    precede::Vector{Tuple{Int,Int}}
end

"""
    _Structured

A model's structured declarations, keyed by the index of each handle variable:
its permutations and its lookup tables (name and entries). Held in
`model.ext[:quicopt_structured]` and read by `import_model`.
"""
struct _Structured
    permutations::Dict{MOI.VariableIndex,_PermutationDecl}
    tables::Dict{MOI.VariableIndex,Pair{Symbol,Array{Float64}}}
end

_structured!(m::JuMP.Model) =
    get!(() -> _Structured(Dict{MOI.VariableIndex,_PermutationDecl}(),
                           Dict{MOI.VariableIndex,Pair{Symbol,Array{Float64}}}()),
         m.ext, :quicopt_structured)::_Structured
_structured(m::JuMP.Model) = get(m.ext, :quicopt_structured, nothing)

"""
    _declare_handle!(m, name) -> (record, handle)

Check that `name` is free among the model's permutations and lookup tables, and
create the handle variable that will stand for the new declaration.
"""
function _declare_handle!(m::JuMP.Model, name::Symbol)
    st = _structured!(m)
    taken = Set{Symbol}(d.name for d in values(st.permutations)) ∪
            Set{Symbol}(t.first for t in values(st.tables))
    name in taken && error("the name :$name is already declared on this model")
    return st, JuMP.@variable(m, base_name = String(name))
end

# ── permutations ─────────────────────────────────────────────────────────────

"""
    Permutation

A permutation declared by [`permutation`](@ref): `n` items placed in `n` slots,
one item per slot, both numbered from 1. Read it with [`item_at`](@ref) and
[`slot_of`](@ref); constrain it with [`precede!`](@ref).
"""
struct Permutation
    handle::JuMP.VariableRef
    name::Symbol
    n::Int
end

Base.broadcastable(P::Permutation) = Ref(P)
Base.show(io::IO, P::Permutation) =
    print(io, "permutation :", P.name, " (", P.n, " items in ", P.n, " slots)")

"""
    permutation(model, name, n; start = nothing) -> Permutation

Declare an order as a decision: `n` items placed in `n` slots, one item per
slot. For a route the items are the stops and the slots are the visits, so slot
1 holds the first stop visited; for a machine the items are the jobs and the
slots the positions in its queue.

`name` identifies the permutation in the result, as
`result.structures[name]`. `n` is at least 2. `start` is the arrangement the
service's search starts from: `start[i]` is the slot of item `i`, so it holds
each of `1:n` once. Left out, item `i` starts in slot `i`.

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
function permutation(m::JuMP.Model, name::Union{Symbol,AbstractString}, n::Integer; start = nothing)
    n ≥ 2 || error("a permutation has at least 2 items, got $n")
    nm = Symbol(name)
    s = start === nothing ? Int[] : collect(start)
    isempty(s) || (all(x -> x isa Integer, s) && sort(s) == 1:n) ||
        error("permutation :$nm: start must hold each of 1 to $n once " *
              "(start[i] is the slot item i starts in)")
    st, handle = _declare_handle!(m, nm)
    st.permutations[JuMP.index(handle)] = _PermutationDecl(nm, Int(n), Int.(s), Tuple{Int,Int}[])
    return Permutation(handle, nm, Int(n))
end

"""
    _position(k, P, what, caller) -> Int

Check that `k`, a slot or an item of `P`, is a whole number in `1:P.n`.
"""
function _position(k, P::Permutation, what, caller)
    k isa Integer || error("$caller: a $what is a whole number, got $(repr(k))")
    1 ≤ k ≤ P.n || error("$caller: permutation :$(P.name) has $(what)s 1 to $(P.n), got $k")
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
    _has_cycle(vcat(decl.precede, [(a, b)]), P.n) &&
        error("requiring $a before $b contradicts the requirements already given for :$(P.name)")
    push!(decl.precede, (a, b))
    return P
end

"""
    _has_cycle(edges, n) -> Bool

Whether the `(before, after)` requirements over items `1:n` contradict each
other: Kahn's algorithm leaves an item unplaced exactly when they contain a
cycle.
"""
function _has_cycle(edges, n::Int)
    indegree = zeros(Int, n)
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
    return placed < n
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
between the first and the second stop of a route whose order the service is
still choosing, or the price of an option an integer variable picks. A Julia
array cannot be indexed this way; the table returned here can.

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
    _structure_decls(st) -> Vector{StructureDecl}

The model's permutations as wire declarations, in canonical (name-sorted) order.
A start that places an item after one it must follow is refused here, where
both are known; the service would refuse it too.
"""
function _structure_decls(st::_Structured)
    decls = _pb.StructureDecl[]
    for d in sort(collect(values(st.permutations)); by = d -> String(d.name))
        for (a, b) in d.precede
            isempty(d.start) || d.start[a] < d.start[b] ||
                error("permutation :$(d.name): the start places item $a after item $b, which it must precede")
        end
        push!(decls, _pb.StructureDecl(name = String(d.name), kind = "permutation", size = UInt64(d.n),
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

# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# Shared JuMP fixtures, imported by BOTH the public golden test (here) and the
# private verification harness. Keeping them in one
# place means the two test layers exercise exactly the same models.
module Fixtures

using JuMP
using QuicoptClient   # set_distribution / set_scenarios / aggregators, for the stochastic fixtures
include(joinpath(@__DIR__, "power", "PowerVertical.jl"))
using .PowerVertical

export models, stochastic_models, structured_models, three_bus, acopf_jump, acopf_uc_jump

"""
    models() -> Vector{Pair{String,JuMP.Model}}

Each `name => model` is one import facet; `name` is also the golden file stem.
"""
function models()
    out = Pair{String,Model}[]

    # nonlinear objective (^, /), box bounds, no constraints
    m = Model(); @variable(m, 0.1 <= x <= 10); @objective(m, Min, x^2 + 1 / x)
    push!(out, "scalar_nlp" => m)

    # quadratic objective + nonlinear (exp) ≤ constraint
    m = Model(); @variable(m, -5 <= x <= 5); @variable(m, -5 <= y <= 5)
    @objective(m, Min, (x - 3)^2 + (y - 3)^2); @constraint(m, exp(x) + exp(y) <= 4)
    push!(out, "quad_exp_le" => m)

    # quadratic with an off-diagonal (x·y) term
    m = Model(); @variable(m, -5 <= x <= 5); @variable(m, -5 <= y <= 5)
    @objective(m, Min, x^2 + x * y + y^2 - 3 * x)
    push!(out, "quad_offdiag" => m)

    # Max sense
    m = Model(); @variable(m, 0 <= x <= 4); @variable(m, 0 <= y <= 4)
    @objective(m, Max, 3x + 2y - x^2 - y^2); @constraint(m, x + y <= 5)
    push!(out, "maximize" => m)

    # unbounded: x free (−∞,∞), y half-bounded [−2,∞)
    m = Model(); @variable(m, x); @variable(m, y >= -2)
    @objective(m, Min, (x - 1)^2 + (y + 1)^2 + x * y); @constraint(m, x + y == 3)
    push!(out, "unbounded" => m)

    # linear program — the free tier's `:lp` class (a real solve, not a 422)
    m = Model(); @variable(m, 0 <= x <= 4); @variable(m, 0 <= y <= 4)
    @objective(m, Max, 3x + 2y); @constraint(m, x + y <= 5); @constraint(m, x + 3y <= 9)
    push!(out, "lp" => m)

    # mixed-integer linear program — a general integer + a binary, the `:milp` class
    m = Model(); @variable(m, 0 <= x <= 10, Int); @variable(m, y, Bin)
    @objective(m, Max, 4x + 7y); @constraint(m, 2x + 3y <= 12)
    push!(out, "milp" => m)

    # the PowerVertical mirror — AC-OPF and unit commitment
    g = three_bus()
    push!(out, "acopf" => acopf_jump(g))
    push!(out, "unit_commitment" => acopf_uc_jump(g))

    out
end

"""
    stochastic_models() -> Vector{Pair{String,JuMP.Model}}

Stochastic fixtures — kept OUT of [`models`](@ref), whose consumers drive every
entry through a deterministic solve; these author the stochastic layer
(`set_distribution`, `set_scenarios`, aggregator heads) and exist to lock the
wire bytes and the importer's source rewriting.
"""
function stochastic_models()
    out = Pair{String,Model}[]

    # the newsvendor: parametric draw, expectation, max — the canonical two-stage toy
    m = Model()
    @variable(m, 0 <= x <= 200)
    @variable(m, demand)
    set_distribution(m, demand, :normal, 100.0, 15.0)
    set_scenarios(m, 512; seed = 42)
    @objective(m, Min, 3x + 10 * expectation(max(demand - x, 0)))
    push!(out, "newsvendor_stoch" => m)

    # empirical column + CVaR objective + a chance constraint (sfreq head)
    m = Model()
    @variable(m, 0 <= x <= 100)
    @variable(m, shock)
    set_distribution(m, shock, [0.9, 1.0, 1.1, 1.3])
    set_scenarios(m, 4)
    @objective(m, Min, x + cvar(shock * (50 - x), 0.95))
    @constraint(m, prob(shock * 40 - x, ≤, 0.0) >= 0.75)
    push!(out, "empirical_chance" => m)

    out
end

"""
    structured_models() -> Vector{Pair{String,JuMP.Model}}

Structured fixtures — permutations, partitions, lookup tables, domains with a
hole and blocks — kept OUT of
[`models`](@ref) for the same reason as the stochastic ones: they lock the wire
bytes and the importer's handling of handles, and no deterministic solver reads
them.
"""
function structured_models()
    out = Pair{String,Model}[]

    # a route: a two-index lookup over item_at, with a precedence
    position = [0, 3, 1, 4, 2]
    m = Model()
    dist = lookup_table(m, :dist, [abs(a - b) for a in position, b in position])
    route = permutation(m, :route, 5)
    precede!(route, 4, 1)
    @objective(m, Min, sum(dist[item_at(k, route), item_at(k + 1, route)] for k in 1:4))
    push!(out, "route" => m)

    # an assignment: slot_of in a lookup weighted by data, a start, a constraint
    # on a part, and a plain variable beside the structure
    m = Model()
    @variable(m, 0 <= y <= 1)
    distance = lookup_table(m, :distance, [abs(a - b) for a in (0, 1, 3), b in (0, 1, 3)])
    place = permutation(m, :place, 3; start = [2, 1, 3])
    flow = [(1, 2) => 2.0, (1, 3) => 5.0, (2, 3) => 1.0]
    @objective(m, Min, sum(w * distance[slot_of(f, place), slot_of(g, place)] for ((f, g), w) in flow) + y)
    @constraint(m, slot_of(1, place) <= 2)
    push!(out, "assignment" => m)

    # a lookup alone: the price of the option an integer variable picks
    m = Model()
    @variable(m, 1 <= choice <= 4, Int)
    price = lookup_table(m, :price, [3.0, 1.0, 4.0, 1.5])
    @objective(m, Min, price[choice])
    push!(out, "lookup_choice" => m)

    # holes and blocks: a semi-integer and a semicontinuous variable, a fee on
    # the first one's use, a step and a min over sums, a binary, and two blocks
    m = Model()
    @variable(m, q in Semiinteger(10, 25))
    @variable(m, r in Semicontinuous(2.5, 8))
    @variable(m, s, Bin)
    @variable(m, 0 <= x[1:2] <= 4, Int)
    @objective(m, Min, 1.5q + 2r + 30active(q) + 40ifelse(x[1] + x[2] >= 1, 1, 0) -
                       5min(1, active(q) + active(r)))
    @constraint(m, q + r >= 12)
    @constraint(m, 8s - r >= 0)
    @constraint(m, x[1] + x[2] >= 3)
    block(m, :supply, [q, r, s])
    block(m, :pair, x)
    push!(out, "holes_blocks" => m)

    # a partition with a start, read through a lookup at an item's part and
    # through the sizes of its parts
    m = Model()
    @variable(m, 0 <= y <= 5)
    cost = lookup_table(m, :cost, [2.0, 0.5])
    teams = partition(m, :teams, 5, 2; start = [1, 2, 1, 2, 1])
    @objective(m, Min, cost[part_of(1, teams)] + cost[part_of(3, teams)] +
                       (size_of(1, teams) - size_of(2, teams))^2 + y)
    push!(out, "partition" => m)

    out
end

end

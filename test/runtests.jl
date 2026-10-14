# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
using QuicoptClient
using JuMP
using Test
import ProtoBuf as PB

include("fixtures.jl")
using .Fixtures

# Public, dependency-free regression. Import each fixture, encode, and lock the
# bytes against a committed golden — a guard against *self*-drift in the importer
# or the generated codec. It deliberately does NOT prove correctness against the
# service's reference codec: that is decode-equivalence (the client's bytes decode
# to the intended `Program`) plus an evaluation differential, which couple to the
# closed reference and so live in a separate, private verification harness. This
# repo depends on JuMP + ProtoBuf only.
#
# Regenerate goldens after an intended schema/importer change:
#     julia --project=. gen/goldens.jl
const GOLDENS = joinpath(@__DIR__, "goldens")

@testset "QuicoptClient" begin
    @testset "wire bytes match golden — $name" for (name, m) in
            vcat(Fixtures.models(), Fixtures.stochastic_models(), Fixtures.structured_models())
        golden = joinpath(GOLDENS, name * ".hex")
        @test isfile(golden)
        @test bytes2hex(QuicoptClient.encode(QuicoptClient.import_model(m))) == read(golden, String)
    end

    # The stochastic importer rewrite, checked structurally on its own structs:
    # a source never becomes a decision variable, its uses become source
    # references, declarations carry the distribution, and the scenario fields
    # ride along. (Whether the SERVICE accepts these bytes is decode-equivalence,
    # which lives in the private verification harness like all of it.)
    @testset "stochastic authoring — sources are declarations, not variables" begin
        _pb = QuicoptClient._pb

        m = Fixtures.stochastic_models()[1].second          # the newsvendor
        prog = QuicoptClient.import_model(m)
        @test [v.name for v in prog.vars] == ["x1"]         # demand is gone from the decision set
        @test [d.name for d in prog.sources] == ["demand"]
        @test prog.sources[1].kind.name === :parametric
        @test prog.sources[1].kind[].head == "normal"
        @test prog.scenarios == 512 && prog.scenario_seed == 42

        # the bytes round-trip through the generated codec with everything intact
        p2 = PB.decode(PB.ProtoDecoder(IOBuffer(QuicoptClient.encode(prog))), _pb.Program)
        @test [d.name for d in p2.sources] == ["demand"] && p2.scenarios == 512

        # empirical column survives, packed
        pe = QuicoptClient.import_model(Fixtures.stochastic_models()[2].second)
        @test pe.sources[1].kind.name === :empirical
        @test pe.sources[1].kind[].data == [0.9, 1.0, 1.1, 1.3]

        # a deterministic model emits NO stochastic fields (additive-only)
        md = Model(); @variable(md, 0 <= y <= 1); @objective(md, Min, y)
        pd = QuicoptClient.import_model(md)
        @test isempty(pd.sources) && pd.scenarios == 0 && pd.scenario_seed == 0

        # authoring guardrails
        mb = Model(); @variable(mb, 0 <= w <= 1)
        set_distribution(mb, w, :normal, 0.0, 1.0)
        @test_throws ErrorException QuicoptClient.import_model(mb)      # bounds on a random variable

        ma = Model(); v = @variable(ma)
        @test_throws ErrorException set_distribution(ma, v, :normal, 0.0, 1.0)  # anonymous, no name

        mc = Model(); @variable(mc, a); @variable(mc, b)
        set_distribution(mc, a, :normal, 0.0, 1.0)
        @test_throws ErrorException set_distribution(mc, b, :normal, 0.0, 1.0; name = :a)  # name collision

        @test_throws ErrorException set_scenarios(mc, 0)                # R ≥ 1
        @test_throws ErrorException set_scenarios(mc, 4; seed = 0)      # 0 reserved

        # the relation binds to x, and only ≤ / ≥ have scenario counterparts
        @test prob(a, ≤, 0).head === prob(a, <=, 0).head === :sfreq_leq
        @test prob(a, ≥, 0).head === :sfreq_geq
        @test_throws ErrorException prob(a, <, 0)
    end

    # The structured importer, checked on its own structs: a handle never becomes
    # a decision variable, a part reads its permutation by name, a lookup reads
    # its table by name, and the declarations carry size, start and precedences.
    @testset "structured authoring — permutations and lookup tables" begin
        _pb = QuicoptClient._pb
        fx = Dict(Fixtures.structured_models())

        # every node of one kind in an expression tree, in depth-first order
        nodes(e, kind) = e.node.name === kind ? [e.node[]] :
                         e.node.name === :apply ? reduce(vcat, [nodes(a, kind) for a in e.node[].args]; init = Any[]) :
                         Any[]
        # every operator name in an expression tree
        ops(e) = e.node.name === :apply ? vcat([e.node[].op], [ops(a) for a in e.node[].args]...) : String[]

        route = QuicoptClient.import_model(fx["route"])
        @test isempty(route.vars)                            # the handles are not decisions
        @test only(route.structures).name == "route" && only(route.structures).size == 5
        @test [(p.before, p.after) for p in only(route.structures).precede] == [(4, 1)]
        @test only(route.params).name == "dist" && length(only(route.params).entries) == 25
        legs = nodes(route.objective, :table)
        @test length(legs) == 4 && all(l -> l.param == "dist", legs)
        part = legs[1].index[1].node[]
        @test part.op == "item_at" && part.args[1].node[] == 1.0
        @test part.args[2].node.name === :structure && part.args[2].node[].name == "route"

        assignment = QuicoptClient.import_model(fx["assignment"])
        @test [v.name for v in assignment.vars] == ["x1"]   # y, declared first
        @test only(assignment.structures).start == [2, 1, 3]
        @test "slot_of" in ops(only(assignment.constraints).f)

        choice = QuicoptClient.import_model(fx["lookup_choice"])
        lookup = choice.objective.node[]
        @test lookup.param == "price" && lookup.index[1].node.name === :var

        # the bytes round-trip through the generated codec with the declarations intact
        p2 = PB.decode(PB.ProtoDecoder(IOBuffer(QuicoptClient.encode(route))), _pb.Program)
        @test only(p2.structures).name == "route" && only(p2.structures).kind == "permutation"

        # a model without them emits none
        md = Model(); @variable(md, 0 <= z <= 1); @objective(md, Min, z)
        pd = QuicoptClient.import_model(md)
        @test isempty(pd.structures) && isempty(pd.params)

        # whole-number indices read the data itself
        m = Model(); t = lookup_table(m, :t, [1.0 2.0; 3.0 4.0])
        @test t[2, 1] == 3.0

        # authoring guardrails
        m = Model()
        @test_throws ErrorException permutation(m, :p, 1)                       # at least 2 items
        @test_throws ErrorException permutation(m, :p, 3; start = [1, 1, 2])    # not an arrangement
        P = permutation(m, :p, 3)
        @test P.n_items == 3 && sprint(show, P) == "permutation :p (3 items in 3 slots)"
        @test_throws ErrorException permutation(m, :p, 4)                       # name taken
        @test_throws ErrorException lookup_table(m, :p, [1.0])                  # across both kinds
        @test_throws ErrorException item_at(4, P)
        @test_throws ErrorException slot_of(1.5, P)
        @test_throws ErrorException precede!(P, 2, 2)
        precede!(precede!(P, 1, 2), 2, 3)
        @test_throws ErrorException precede!(P, 3, 1)                           # a cycle
        @test_throws ErrorException lookup_table(m, :e, Float64[])
        @test_throws ErrorException lookup_table(m, :n, [1.0, NaN])
        @test_throws ErrorException t[3, 1]                                     # outside the table
        @test_throws ErrorException t[1.5, 1]

        ms = Model(); Q = permutation(ms, :q, 3; start = [1, 2, 3]); precede!(Q, 3, 1)
        @objective(ms, Min, slot_of(1, Q))
        @test_throws ErrorException QuicoptClient.import_model(ms)              # start breaks a precedence

        mn = Model(); @variable(mn, 0 <= w <= 1); R = permutation(mn, :x1, 2)
        @objective(mn, Min, w + item_at(1, R))
        @test_throws ErrorException QuicoptClient.import_model(mn)              # named like a variable

        mh = Model(); H = permutation(mh, :h, 2)
        @objective(mh, Min, H.handle)
        @test_throws ErrorException QuicoptClient.import_model(mh)              # the handle used as a number
    end

    # Domains with a hole, `active`, `ifelse`, blocks and partitions, checked on
    # the importer's own structs.
    @testset "holes, blocks and partitions" begin
        _pb = QuicoptClient._pb
        fx = Dict(Fixtures.structured_models())
        ops(e) = e.node.name === :apply ? vcat([e.node[].op], [ops(a) for a in e.node[].args]...) : String[]
        hb = QuicoptClient.import_model(fx["holes_blocks"])
        @test [(v.name, v.domain) for v in hb.vars] ==
              [("x1", _pb.Domain.SEMIINTEGER), ("x2", _pb.Domain.SEMICONTINUOUS), ("x3", _pb.Domain.BINARY),
               ("x4", _pb.Domain.INTEGER), ("x5", _pb.Domain.INTEGER)]
        @test (hb.vars[1].lower.kind[], hb.vars[1].upper.kind[], hb.vars[1].start) == (10.0, 25.0, 0.0)
        @test [b.name for b in hb.blocks] == ["pair", "supply"]                 # sorted by name
        @test [m.name for m in hb.blocks[2].members] == ["x1", "x2", "x3"]      # in the order given
        @test count(==("indicator"), ops(hb.objective)) == 3 && count(==("step"), ops(hb.objective)) == 1

        pt = QuicoptClient.import_model(fx["partition"])
        d = only(pt.structures)
        @test (d.name, d.kind, d.size, d.parts, d.start) == ("teams", "partition", 5, 2, [1, 2, 1, 2, 1])
        @test count(==("part_of"), ops(pt.objective)) == 0                      # inside the lookups
        @test count(==("size_of"), ops(pt.objective)) == 2

        # ifelse over each comparison: the 0/1 value, then b + (a − b)·t
        # (inside a JuMP macro, where a comparison of variables is an expression)
        m = Model(); @variable(m, 0 <= u <= 9); @variable(m, 0 <= w <= 9)
        objops(m) = ops(QuicoptClient.import_model(m).objective)
        @objective(m, Min, ifelse(u >= w, 1, 0)); @test objops(m) == ["step", "-"]
        @objective(m, Min, ifelse(u <= w, 1, 0)); @test objops(m) == ["step", "-"]
        @objective(m, Min, ifelse(u > w, 1, 0));  @test objops(m) == ["-", "step", "-"]
        @objective(m, Min, ifelse(u < w, 1, 0));  @test objops(m) == ["-", "step", "-"]
        @objective(m, Min, ifelse(u == w, 1, 0)); @test objops(m) == ["-", "indicator", "-"]
        @objective(m, Min, ifelse(u >= 1, 60, 10)); @test "step" in objops(m)
        @objective(m, Min, ifelse(u, 1, 0))
        @test_throws ErrorException QuicoptClient.import_model(m)               # not a comparison

        # a hole's set is the variable's bounds, so they must be finite
        m = Model(); @variable(m, z in Semicontinuous(1.0, Inf)); @objective(m, Min, z)
        @test_throws ErrorException QuicoptClient.import_model(m)

        # blocks: guardrails at declaration and at import
        m = Model(); @variable(m, 0 <= v[1:3] <= 1); @variable(m, f >= 0)
        block(m, :a, v[1:1])
        @test_throws ErrorException block(m, :a, v[2:2])                        # name taken
        @test_throws ErrorException block(m, :b, VariableRef[])                 # empty
        @test_throws ErrorException block(m, :b, [v[2], v[2]])                  # twice
        @test_throws ErrorException block(m, :b, v)                             # v[1] is in :a
        other = Model(); @variable(other, 0 <= o <= 1)
        @test_throws ErrorException block(m, :b, [o])                           # another model
        block(m, :c, [f]); @objective(m, Min, f)
        @test_throws ErrorException QuicoptClient.import_model(m)               # f has no upper bound

        # partitions: guardrails
        m = Model()
        @test_throws ErrorException partition(m, :p, 0, 2)
        @test_throws ErrorException partition(m, :p, 3, 1)
        @test_throws ErrorException partition(m, :p, 3, 2; start = [1, 3, 2])
        P = partition(m, :p, 3, 2)
        @test (P.n_items, P.n_parts) == (3, 2) && sprint(show, P) == "partition :p (3 items in 2 parts)"
        @test_throws ErrorException permutation(m, :p, 3)                       # name taken
        @test_throws ErrorException part_of(4, P)
        @test_throws ErrorException size_of(3, P)
        @test_throws ErrorException part_of(1.5, P)
        @test_throws MethodError item_at(1, P)                                  # not a permutation
    end

    include("transport.jl")
end

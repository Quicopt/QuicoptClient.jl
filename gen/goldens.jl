# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# Regenerate the committed wire-byte goldens from the shared fixtures:
#
#     julia --project=. gen/goldens.jl
#
# The goldens lock the client's *own* encoder output — a regression guard against
# unintended importer/codec drift. Cross-codec correctness (that these bytes
# decode to the intended Program) is proven separately in a private verification
# harness. Re-run this only when a schema/importer change is intended, then commit
# the updated *.hex and eyeball the diff.
using QuicoptClient

include(joinpath(@__DIR__, "..", "test", "fixtures.jl"))
using .Fixtures

const OUT = joinpath(@__DIR__, "..", "test", "goldens")
mkpath(OUT)

for (name, m) in vcat(Fixtures.models(), Fixtures.stochastic_models(), Fixtures.structured_models())
    bytes = QuicoptClient.encode(QuicoptClient.import_model(m))
    write(joinpath(OUT, name * ".hex"), bytes2hex(bytes))
    println("wrote ", name, ".hex  (", length(bytes), " bytes)")
end
